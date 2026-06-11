# Separation of Concerns — LiveViews and Context Functions

Load this file when writing or modifying any LiveView, controller, or
context function. This is the rule that keeps the codebase ready for a
GraphQL API, native mobile apps, or any future transport layer.

> **Baseline:** Phoenix 1.8 · LiveView 1.1. Context functions take a Scope first; LiveViews reference current_scope. Large collections use streams.

---

## The Rule

**LiveViews are thin controllers. Context functions are the application.**

A LiveView's job is:
1. Mount — load initial data by calling context functions
2. Render — present data from assigns using templates
3. Handle events — translate user actions into context function calls
4. Handle info — react to PubSub messages by updating assigns

A LiveView must NEVER:
- Call `MyApp.Repo` directly
- Build Ecto queries
- Contain business rules (domain validation, authorization, state machine logic)
- Perform data aggregation or transformation that a future API would also need
- Execute multi-step operations that should be atomic

**The test: could a GraphQL resolver do this same operation by calling the
same context function with the same arguments?** If the answer is no because
the logic is trapped inside a LiveView, the separation has been violated.

---

## What belongs where

### In the context function

- Database queries (all `MyApp.Repo` calls)
- Business rules ("a post can only be published if its status is ready")
- Authorization ("only admins can delete records")
- Data aggregation ("count items by status for this account")
- Multi-step operations ("create a resource, associate it, and tag it")
- External API calls (e.g. a media/video provider, a payment provider — through client behaviours)
- Event broadcasting
- Audit logging
- Metrics emission
- Error handling with tagged tuples

### In the LiveView

- Extracting parameters from events (`%{"id" => id}`)
- Calling context functions with those parameters
- Pattern matching on context function results to decide what to render
- Assigning data to the socket
- Setting flash messages based on error atoms
- Navigating/redirecting
- Subscribing to PubSub topics
- Updating assigns when PubSub messages arrive
- UI-only state (modal open/closed, tab selection, form changeset tracking)

### The gray area — presenter/formatter logic

Formatting data for display (e.g. formatting seconds as "mm:ss", building
a thumbnail URL from a media playback ID, formatting currency) lives in a
**view helper or component**, not in the context and not inline in the
LiveView's `handle_event`. These are presentation concerns.

```elixir
# ✅ In a helper/component module
def format_duration(seconds) when is_number(seconds) do
  minutes = trunc(seconds / 60)
  secs = trunc(rem(trunc(seconds), 60))
  "#{minutes}:#{String.pad_leading("#{secs}", 2, "0")}"
end

def media_thumbnail_url(playback_id, opts \\ []) do
  width = Keyword.get(opts, :width, 400)
  height = Keyword.get(opts, :height, 225)
  # Construct the URL for your media/video provider here
  "https://media.example.com/#{playback_id}/thumbnail.webp?width=#{width}&height=#{height}"
end
```

JS hooks are also presentation-layer bridges — they stay thin and hold no
business logic (see `typescript-hooks.md`).

---

## Scope is the first argument

Context functions take a `%MyApp.Accounts.Scope{}` as their **first** argument,
uniformly. The scope carries the `user` and, for multi-tenant apps, the
`account`/`organization` and optional `permissions`. LiveViews and controllers
reference `socket.assigns.current_scope` / `conn.assigns.current_scope` and pass
it straight through.

```elixir
Posts.get_post!(scope, id)        # ✅ scope first, every function
Posts.delete_post(scope, post)    # ✅
Posts.create_post(scope, attrs)   # ✅

Posts.get_post!(org, id)          # ❌ don't pass the bare account/organization
```

Pass the whole scope; let the context read the field it needs
(`scope.account.id`) and apply the tenant filter. This is the
[strongly-recommended generated default](https://phoenix.hexdocs.pm/scopes.html)
in Phoenix 1.8 ([1.8 release](https://www.phoenixframework.org/blog/phoenix-1-8-released)),
not an absolute — the `Scope` struct's shape is yours to customize, and adoption
can be incremental.

### Scopes are data boundaries, not authorization

A scope answers *"which rows is this actor allowed to see?"* — a **data
boundary**. It does not answer *"is this actor allowed to perform this action?"*
— that is **authorization**, a separate rule. Both belong in the context
function, not the LiveView: the context applies the scope filter to its queries
*and* checks permitted actions, returning `{:error, :forbidden}` when an action
is not allowed ([scopes vs. authorization](https://curiosum.com/blog/phoenix-scopes-authorization-permit-phoenix)).

---

## Patterns

### Correct: simple event → context call → assign result

```elixir
def handle_event("delete_post", %{"id" => id}, socket) do
  post = Posts.get_post!(socket.assigns.current_scope, id)

  case Posts.delete_post(socket.assigns.current_scope, post) do
    {:ok, _deleted} ->
      {:noreply,
       socket
       |> put_flash(:info, "Post deleted.")
       |> push_navigate(to: ~p"/admin/posts")}

    {:error, :forbidden} ->
      {:noreply, put_flash(socket, :error, "You don't have permission to delete this post.")}
  end
end
```

### Correct: mount loads data via context, no transformation

```elixir
def mount(_params, _session, socket) do
  scope = socket.assigns.current_scope

  %{results: posts} = Posts.list_posts(scope, per_page: 25)
  stats = Posts.post_stats(scope)

  {:ok, assign(socket,
    posts: posts,
    stats: stats,
    page_title: scope.account.name
  )}
end
```

The account/organization is a **field on the scope** (`scope.account`,
`scope.organization`, `scope.permissions`) — never a parallel `current_account`
assign alongside `current_scope`. Pass the whole `scope` to context functions
and let them read the field they need.

This bounded list (`per_page: 25`) correctly stays in assigns. For **large or
unbounded collections**, render with a [LiveView stream](https://fly.io/phoenix-files/phoenix-dev-blog-streams/)
instead, so the full list never lives in socket memory:

```elixir
def mount(_params, _session, socket) do
  scope = socket.assigns.current_scope
  %{results: posts} = Posts.list_posts(scope)  # large/unbounded fetch
  {:ok, stream(socket, :posts, posts)}
end
```

`phx.gen.live` defaults to streams for collections in Phoenix 1.8
([1.8 release notes](https://www.phoenixframework.org/blog/phoenix-1-8-released)).
Streams are a tool, not the universal lean-assigns mechanism — the LiveView 1.1
release notes call them "not a one size fits all solution" and add **keyed
comprehensions** as an alternative for some cases. Update streamed items with
`stream_insert/3` (there is no `stream_update`); delete with `stream_delete/3`.

### Correct: PubSub handler updates a single assign

```elixir
def handle_info({:my_app_event, {:post_published, post}, _scope}, socket) do
  {:noreply, update_post_in_list(socket, post)}
end

defp update_post_in_list(socket, updated_post) do
  posts = Enum.map(socket.assigns.posts, fn p ->
    if p.id == updated_post.id, do: updated_post, else: p
  end)
  assign(socket, posts: posts)
end
```

### Violation: business rule leaked into LiveView

```elixir
# ❌ The "can only publish if ready" rule belongs in the context
def handle_event("publish", %{"id" => id}, socket) do
  post = Posts.get_post!(socket.assigns.current_scope, id)

  if post.status == "ready" do
    Posts.update_post(socket.assigns.current_scope, post, %{published: true})
    {:noreply, put_flash(socket, :info, "Published.")}
  else
    {:noreply, put_flash(socket, :error, "Post must be ready to publish.")}
  end
end
```

Fix: create `Posts.publish_post(scope, post)` that checks the status
internally and returns `{:error, :not_ready}` if it fails.

### Violation: Repo call in LiveView

```elixir
# ❌ Direct database access
def mount(_params, _session, socket) do
  posts = MyApp.Repo.all(
    from p in Post,
    where: p.account_id == ^socket.assigns.current_scope.account.id,
    where: is_nil(p.deleted_at),
    order_by: [desc: :inserted_at]
  )
  {:ok, assign(socket, posts: posts)}
end
```

Fix: call `Posts.list_posts(current_scope)`.

### Violation: multi-step operation in LiveView

```elixir
# ❌ Three context calls that should be one atomic operation
def handle_event("quick_publish", params, socket) do
  {:ok, post} = Posts.create_post(scope, params)
  {:ok, _} = Posts.add_post_to_collection(scope, featured_collection, post)
  {:ok, _} = Posts.publish_post(scope, post)
  {:noreply, ...}
end
```

Fix: create `Posts.create_and_publish_post(scope, params, collection)` that
wraps all three in a transaction.

#### Wrapping multi-step writes atomically

Two mainstream ways to make a multi-step write atomic — pick whichever reads
clearer for the operation; both are equally valid:

`Ecto.Multi` — named, inspectable steps with a single rollback if any step
fails ([docs](https://hexdocs.pm/ecto/Ecto.Multi.html)):

```elixir
def create_and_publish_post(scope, attrs, collection) do
  Ecto.Multi.new()
  |> Ecto.Multi.insert(:post, Post.changeset(%Post{account_id: scope.account.id}, attrs))
  |> Ecto.Multi.insert(:link, fn %{post: post} ->
    CollectionPost.changeset(%CollectionPost{}, %{post_id: post.id, collection_id: collection.id})
  end)
  |> Ecto.Multi.update(:publish, fn %{post: post} -> Post.publish_changeset(post) end)
  |> Repo.transaction()
  |> case do
    {:ok, %{publish: post}} ->
      Events.broadcast(scope, {:post_published, post})  # AFTER commit, never inside a step
      {:ok, post}

    {:error, _step, changeset, _changes} ->
      {:error, :validation, changeset}
  end
end
```

`Repo.transact/2` (Ecto 3.13+) with a `with` block — sequential composition of
existing context functions that already return tagged tuples:

```elixir
def create_and_publish_post(scope, attrs, collection) do
  result =
    Repo.transact(fn ->
      with {:ok, post} <- create_post(scope, attrs),
           {:ok, _link} <- add_post_to_collection(scope, collection, post),
           {:ok, published} <- publish_post(scope, post) do
        {:ok, published}
      end
    end)

  # Any non-`{:ok, _}` from the callback rolls back and is returned verbatim,
  # so the function's own tagged tuples (e.g. `{:error, :validation, changeset}`)
  # propagate unchanged. Match `{:ok, _}` for the commit side effect; let
  # everything else pass through.
  case result do
    {:ok, post} ->
      Events.broadcast(scope, {:post_published, post})  # AFTER commit
      {:ok, post}

    error ->
      error
  end
end
```

In both cases, **broadcast events only after the transaction commits** — never
inline inside a Multi step or `transact` callback, or subscribers may act on a
write that later rolls back.

---

## When context functions need to be created

If an audit or a new feature reveals that a LiveView needs to do something
that no context function supports, create the context function first:

1. Define the function in the appropriate context module
2. Implement the business logic
3. Add a `@doc` with a doctest
4. Wrap in `Telemetry.with_span`
5. Broadcast events if mutating
6. Return tagged tuples
7. Write tests
8. THEN call it from the LiveView

Never skip steps 1–7 and just put the logic in the LiveView "temporarily."
Temporary code in LiveViews becomes permanent debt the moment you need a
GraphQL API or a mobile app.

---

## Multi-tenancy note

If your app is multi-tenant, every context function that touches tenant-scoped
data must accept the `current_scope` struct (which may carry the user and, for
multi-tenant apps, the account/organization) and apply a corresponding filter.
See `architecture-decisions.md` for query scoping patterns.
LiveViews must never construct their own tenant filter — the context function is
responsible for enforcing that boundary.

---

## Checklist for every LiveView change

Before committing changes to any LiveView:

- [ ] No `MyApp.Repo.` calls in the module
- [ ] No `Ecto.Changeset.` calls (except assigning form changesets)
- [ ] No `from(` or `|> where(` query building
- [ ] No business rule conditionals in `handle_event`
- [ ] No multi-step context call sequences in `handle_event`
- [ ] No direct role/permission checks
- [ ] No data aggregation that a GraphQL resolver would also need
- [ ] Every context function called exists and has tests
- [ ] Every error case from context functions is handled in the LiveView

---

## Related docs

- `architecture-decisions.md` — error tuples, audit logging, soft deletes, pagination, events
- `external-service-integration.md` — client behaviour pattern for third-party APIs (e.g. media/video provider)
- `payment-integration.md` — payment provider client and webhook handling
- `object-storage-integration.md` — S3-compatible object store integration
- `theming.md` — per-tenant or per-environment theme configuration
- `design-system.md` — visual design tokens and component conventions
- `testing.md` — factory patterns, mocks, test categories
- `multi-tenancy.md` — tenant scoping, query patterns, test isolation (if applicable)
