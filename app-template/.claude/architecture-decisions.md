# Architecture Decisions

Load this file when creating new schemas, context functions, or system
infrastructure. These patterns are decisions made early to avoid costly
retrofits later. Follow them in all new code.

---

## Audit Logging

Every context function that creates, updates, or deletes a record must write
an audit log entry. No exceptions.

### Schema

```elixir
schema "audit_logs" do
  belongs_to :user, User
  # If multi-tenant: belongs_to :organization, Organization
  field :action, :string         # "post.created", "member.invited", "plan.updated"
  field :resource_type, :string  # "Post", "Membership", "Plan"
  field :resource_id, :binary_id
  field :changes, :map           # %{"title" => %{"from" => "old", "to" => "new"}}
  field :metadata, :map          # IP, user agent, impersonation flag
  timestamps(updated_at: false)
end
```

### Usage

Call `MyApp.Audit.log/4` at the end of every mutating context function:

```elixir
def update_post(scope, post, attrs) do
  with {:ok, updated} <- do_update_post(post, attrs) do
    Audit.log(scope, "post.updated", updated, changeset_changes(post, updated))
    {:ok, updated}
  end
end
```

### Action naming convention

Use `resource.verb` format: `post.created`, `post.updated`, `post.deleted`,
`member.invited`, `member.removed`, `subscription.canceled`, `settings.updated`.

### What to log in metadata

- `request_id` — the Phoenix request ID for correlation
- `ip` — remote IP from the request
- `impersonated_by` — admin user ID if impersonating (critical for audit trail)

---

## Request Context

A `MyApp.RequestContext` module stores per-process context that is available
everywhere without passing it through function signatures.

### Set in a plug

```elixir
defmodule MyAppWeb.Plugs.SetRequestContext do
  def call(conn, _opts) do
    MyApp.RequestContext.put(%{
      request_id: Logger.metadata()[:request_id],
      ip: to_string(:inet_parse.ntoa(conn.remote_ip)),
      user_agent: Plug.Conn.get_req_header(conn, "user-agent") |> List.first(),
      scope: conn.assigns[:current_scope]
    })
    conn
  end
end
```

### Access anywhere

```elixir
ctx = MyApp.RequestContext.current()
ctx.request_id  # for structured logs
ctx.ip          # for audit logs
ctx.scope       # for the current user (and tenant, if multi-tenant)
```

### Rules

- Set the request context early in the plug pipeline, after auth resolution
  (and tenant resolution, if multi-tenant).
- The audit logger reads from request context automatically — individual context
  functions do not need to pass request metadata explicitly.
- Oban workers should set their own context at the start of `perform/1` with
  the job's metadata (triggering user, etc.).

---

## Soft Deletes

Never hard-delete user-facing records. Add a `deleted_at` timestamp to every
content-related schema and filter it out by default.

### Which schemas get soft deletes

Apply soft deletes to any record a user would expect to be recoverable or
that has referential significance for other records (e.g. content, plans,
settings, notifications). Examples:

- `Post`, `Resource`, `Collection`, `Tag`
- `Plan`, `Notification`, `WebhookEndpoint`
- If multi-tenant: `Organization` (deactivated, not destroyed)

### Which schemas use hard deletes

Some records are append-only logs or are superseded rather than removed:

- Watch/activity history (append-only log; deletion via data erasure only)
- Progress/state records (overwritten, not deleted)
- Analytics events (append-only log)
- Audit logs (never deleted; retention policy handled separately)
- Memberships/sessions (removing is immediate and permanent)
- Delivery records (pruned by age via Oban cleanup)

### Implementation

Add to every soft-deletable schema:

```elixir
field :deleted_at, :utc_datetime
```

Add a migration for each:

```elixir
alter table(:posts) do
  add :deleted_at, :utc_datetime
end
```

### Query pattern

Every list/get function must exclude soft-deleted records by default:

```elixir
# Correct — filters out deleted records
def list_posts(scope) do
  Post
  |> where(user_id: ^scope.user.id)
  |> where([p], is_nil(p.deleted_at))
  |> order_by(desc: :inserted_at)
  |> Repo.all()
end

# For admin "show deleted" views
def list_posts_including_deleted(scope) do
  Post
  |> where(user_id: ^scope.user.id)
  |> order_by(desc: :inserted_at)
  |> Repo.all()
end
```

If multi-tenant, scope by `organization_id` in addition to any user-level
scoping.

### Deletion function pattern

```elixir
def delete_post(scope, post) do
  post
  |> Ecto.Changeset.change(deleted_at: DateTime.utc_now())
  |> Repo.update()
  |> tap(fn {:ok, deleted} ->
    Audit.log(scope, "post.deleted", deleted, %{})
    Events.broadcast(scope, {:post_deleted, deleted})
  end)
end
```

### Restoration

Provide `restore_post/2` that sets `deleted_at` back to nil. Log it as
`post.restored`.

---

## Pagination on Every List Query

Every context function that returns a list must accept pagination options,
even if the UI doesn't paginate yet.

### Interface

```elixir
def list_posts(scope, opts \\ []) do
  page     = Keyword.get(opts, :page, 1)
  per_page = Keyword.get(opts, :per_page, 25)
  order_by = Keyword.get(opts, :order_by, [desc: :inserted_at])

  query =
    Post
    |> where(user_id: ^scope.user.id)
    |> where([p], is_nil(p.deleted_at))
    |> order_by(^order_by)

  results =
    query
    |> limit(^per_page)
    |> offset(^((page - 1) * per_page))
    |> Repo.all()

  total = Repo.aggregate(query, :count)

  %{
    results:     results,
    page:        page,
    per_page:    per_page,
    total:       total,
    total_pages: ceil(total / per_page)
  }
end
```

### Rules

- Default `per_page` is 25. Max is 100. Enforce the max in the function.
- Always return the pagination metadata alongside results — the UI will
  need it eventually even if it ignores it now.
- For functions where the result set is provably tiny (e.g. `list_memberships`
  for a single account), pagination is optional, but `opts \\ []` should still
  be present.

---

## Event-Driven Side Effects

Mutating context functions broadcast events. Side effects (audit logging,
webhook dispatch, analytics, notifications) are handled by subscribers,
not inline in the context function.

### Broadcasting

```elixir
def create_post(scope, attrs) do
  with {:ok, post} <- do_create_post(scope, attrs) do
    MyApp.Events.broadcast(scope, {:post_created, post})
    {:ok, post}
  end
end
```

### Subscribing

```elixir
defmodule MyApp.Events.AuditSubscriber do
  @events [:post_created, :post_updated, :post_deleted,
           :member_invited, :member_removed, :subscription_canceled]

  def handle_event(scope, {event, resource}) when event in @events do
    Audit.log(scope, format_action(event), resource, %{})
  end
end

defmodule MyApp.Events.WebhookSubscriber do
  def handle_event(scope, {event, resource}) do
    Webhooks.dispatch(scope, event, resource)
  end
end
```

### Implementation

Use Phoenix PubSub for in-process event distribution. The `MyApp.Events`
module is a thin wrapper:

```elixir
defmodule MyApp.Events do
  def broadcast(scope, event) do
    # If multi-tenant, scope by org: "events:#{scope.organization.id}"
    Phoenix.PubSub.broadcast(
      MyApp.PubSub,
      "events:#{scope.user.id}",
      {event, scope}
    )
    # Also broadcast to global topic for platform-wide listeners
    Phoenix.PubSub.broadcast(MyApp.PubSub, "events:global", {event, scope})
  end
end
```

### Rules

- Context functions only broadcast events — they do not call audit, webhook,
  or notification modules directly.
- Adding a new side effect means adding a new subscriber, not modifying an
  existing context function. This preserves the "tests are a contract" rule.
- Events are fire-and-forget from the context function's perspective. If a
  subscriber fails, it must not break the primary operation.
- For side effects that must be reliable (e.g. webhook delivery), the subscriber
  enqueues an Oban job rather than doing the work inline.

---

## Idempotency Keys on External API Calls

Every call to an external service (a payment provider, a media/video provider,
etc.) must include an idempotency key.

### Pattern

```elixir
defmodule MyApp.ExternalServiceClient do
  @impl true
  def create_resource(params) do
    key = idempotency_key("create_resource", params.user_id, params.name)
    # Pass key in the API request headers or body as required by the provider
  end

  defp idempotency_key(operation, user_id, resource_identifier) do
    "#{operation}:#{user_id}:#{resource_identifier}:#{Date.utc_today()}"
  end
end
```

### Rules

- Generate deterministic keys from operation + user (or tenant) + resource
  identifier + date bucket. This ensures retries within the same day reuse
  the same key.
- Never generate random idempotency keys — that defeats the purpose.
- Log the idempotency key at `debug` level for troubleshooting.

---

## Feature Flags

Resources (users or, if multi-tenant, organizations) have a `features` JSONB
column for feature gating.

### Schema

```elixir
# On User or Organization
field :features, :map, default: %{}
```

### Helper

```elixir
defmodule MyApp.Features do
  @doc """
  Checks if a feature is enabled for the given resource.

      iex> user = %User{features: %{"advanced_export" => true}}
      iex> MyApp.Features.enabled?(user, :advanced_export)
      true

      iex> user = %User{features: %{}}
      iex> MyApp.Features.enabled?(user, :advanced_export)
      false
  """
  def enabled?(%{features: features}, feature) do
    Map.get(features || %{}, to_string(feature), false)
  end
end
```

### Usage in LiveViews

```elixir
<div :if={Features.enabled?(@current_user, :advanced_export)}>
  <.link navigate={~p"/admin/export"}>Export</.link>
</div>
```

### Rules

- Default is always `false` — features are opt-in.
- Feature flags gate UI rendering AND context function access. Check both:
  the LiveView should not render the feature, AND the context function should
  return `{:error, :feature_not_enabled}` if called directly.
- Use feature flags for plan-tier differentiation (e.g. free vs. pro vs.
  enterprise).
- Admins can toggle feature flags per user or tenant from the admin panel.

---

## Consistent Error Tuples

All context functions return tagged tuples with specific, serializable error
atoms. This prepares for a future public API without rewriting the context layer.

### Error shapes

```elixir
# Success
{:ok, resource}
{:ok, resource, metadata}

# Validation error (changeset)
{:error, :validation, changeset}

# Not found
{:error, :not_found}

# Authorization
{:error, :forbidden}
{:error, :not_authenticated}

# Business logic
{:error, :plan_limit_reached, %{limit: 100, current: 100}}
{:error, :subscription_required}
{:error, :feature_not_enabled}
{:error, :already_exists}

# External service failure — name the provider
{:error, :payment_provider_error, details}
{:error, :media_provider_error, details}
```

### Rules

- Never return bare `{:error, changeset}` — always tag it as
  `{:error, :validation, changeset}` so the caller knows the error type
  without inspecting the value.
- Never return string error messages from context functions. Strings are for
  the UI layer (LiveView flash messages), not the context layer.
- Error atoms must be meaningful enough to map to HTTP status codes:
  `:not_found` → 404, `:forbidden` → 403, `:validation` → 422,
  `:plan_limit_reached` → 402 or 403.

---

## Data Export (if applicable)

If your app collects significant user data, maintain a
`MyApp.Admin.export_user_data/1` function (or
`MyApp.Admin.export_organization_data/1` if multi-tenant) that exports all
data for a user or tenant. Keep it updated as new schemas are added.

### What to export

Every user-scoped (or tenant-scoped) table, including soft-deleted records
marked with their `deleted_at` timestamp.

### Format

Return a map of lists, serializable to JSON:

```elixir
%{
  user:      user_data,
  posts:     [...],
  audit_logs: [...],
  # etc.
}
```

### Rules

- Update this function every time a new user-scoped schema is added. If you
  add a table and forget to add it here, data portability is broken.
- This is the foundation for GDPR / data-subject-access-request (DSAR) compliance.

---

## Oban Job Tagging

Every Oban job must include the relevant owner identifier (user ID, and
organization ID if multi-tenant) in its args for monitoring and fair scheduling.

### Pattern

```elixir
%{user_id: user.id, post_id: post.id, payload: payload}
|> MyApp.Workers.NotificationProcessor.new()
|> Oban.insert()
```

### Rules

- Never enqueue an Oban job without a user/tenant identifier in the args
  (unless it is genuinely a platform-level job like cleanup or aggregation).
- Use Oban's unique constraints scoped to the owner ID + resource ID where
  appropriate to prevent duplicate processing.
- Log the owner ID at the start of every worker's `perform/1` for
  per-user/per-tenant debugging.

---

## Summary Checklist for New Features

When adding a new feature, verify:

- [ ] New schema has `deleted_at` if it is user-facing content
- [ ] New schema is scoped to the owner (user ID, or organization ID if multi-tenant)
- [ ] Context list functions accept `opts \\ []` with pagination
- [ ] Context list functions filter out soft-deleted records by default
- [ ] Context mutation functions broadcast events via `MyApp.Events`
- [ ] Context mutation functions return specific error atoms, not strings
- [ ] External API calls include idempotency keys
- [ ] Oban jobs include the owner identifier in args
- [ ] Data export function is updated to include the new schema (if applicable)
- [ ] Feature is gated behind a feature flag if it is plan-tier dependent
- [ ] All `data-test` attributes are in place
- [ ] All user pathways have LiveView tests
