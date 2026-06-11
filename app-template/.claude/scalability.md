# Scalability

Load this file when building any feature that handles end-user-facing traffic,
writes high-frequency data, or introduces new database queries. Every feature
should be built with the assumption that the platform will eventually support
a large number of concurrent users.

We don't need to handle that load today. We need to make decisions today that
don't prevent us from handling it later.

> **Baseline:** Phoenix 1.8 · LiveView 1.1 · Tailwind v4 + daisyUI v5 · Ecto 3.13+ · OTP 27. Streams = LiveView 0.18+/Phoenix 1.7+ (generator default in 1.8). Colocated hooks + keyed comprehensions = LiveView 1.1. Scopes = phx.gen.auth default in 1.8.

---

## Guiding Principle

External services (a media provider, a payment provider, an object store) handle
their respective heavy lifting. Your infrastructure handles everything around
them: authentication, session management, page rendering, event tracking,
activity feeds, and the admin dashboard. Design every feature knowing that
high-concurrency users will hit your database, your LiveView connections, your
caches, and your background job queues.

---

## Scopes: Thread the Data Boundary Through Every Context Function

Phoenix 1.8's `phx.gen.auth` generates a `Scope` struct by default
([Scopes guide](https://phoenix.hexdocs.pm/scopes.html),
[1.8 release notes](https://www.phoenixframework.org/blog/phoenix-1-8-released)).
A scope is the data boundary a request operates within — it carries the current
`user` and, for multi-tenant apps, the `organization`/`account` the request
belongs to. Every context function takes `scope` as its **first argument** so the
boundary is explicit and queries can't accidentally cross it.

```elixir
defmodule MyApp.Accounts.Scope do
  @moduledoc """
  Carries the data boundary for a request: the current user and, for
  multi-tenant apps, the organization/account. Scopes are DATA BOUNDARIES,
  not authorization — they decide WHICH records a query touches.
  """
  defstruct user: nil, organization: nil

  def for_user(%MyApp.Accounts.User{} = user) do
    %__MODULE__{user: user}
  end

  # Extend the scope with the tenant boundary once it's resolved
  def put_organization(%__MODULE__{} = scope, organization) do
    %{scope | organization: organization}
  end
end
```

**Wiring (generator default).** A plug builds the scope per request; an
`on_mount` rebuilds it for LiveView:

```elixir
# router pipeline
plug :fetch_current_scope_for_user

# LiveView
on_mount {MyAppWeb.UserAuth, :mount_current_scope}
```

Both assign `current_scope` (the conn/socket assign is `current_scope`, the
function argument is `scope`).

**Context signatures take `scope` first:**

```elixir
def list_posts(scope, opts \\ []), do: # ...
def get_post!(scope, id), do: # ...
def create_post(scope, attrs), do: # ...
```

You can remove scopes with `mix phx.gen.auth --no-scope`. Legacy code that
passes a bare `org_id` can coexist during incremental adoption — wrap the
boundary in a scope as you touch each context.

### Scopes are data boundaries, not authorization

Keep these two layers distinct — they're complementary, not interchangeable:

| Layer | Question it answers | Where it lives |
|---|---|---|
| **Scope** | *Which records* may this query touch? | first arg of every context fn; `where`-clause filtering |
| **Authorization** | *Which actions* is this user allowed to perform? | a policy lib — [LetMe](https://let-me.hexdocs.pm/readme.html), [Permit](https://curiosum.com/blog/phoenix-scopes-authorization-permit-phoenix), or Bodyguard |

A scope ensures a query only sees the current org's rows; authorization decides
whether this user may `:delete` that row. A correct scope does **not** make a
function authorized — gate the action separately ([scopes + authorization with
Permit](https://curiosum.com/blog/phoenix-scopes-authorization-permit-phoenix)).

---

## Database: Protect Postgres from the Hot Path

### Never write high-frequency data directly to Postgres

Any operation that fires more than once per user per minute must not
write directly to `MyApp.Repo`. Use a write buffer that batches and flushes.

**Examples of high-frequency operations:**
- Progress/position tracking (e.g., every 10–30 seconds per user)
- Analytics/activity events (e.g., every play, pause, seek, complete)
- Heartbeat / "still active" pings

**Pattern: Write Buffer**

```elixir
defmodule MyApp.Buffer do
  @moduledoc """
  Behaviour for write buffers that batch high-frequency operations
  and flush periodically.
  """

  @callback write(key :: term(), value :: term()) :: :ok
  @callback flush() :: :ok
end
```

The default implementation uses ETS with a GenServer that flushes to Postgres
on a timer (every 30 seconds) or when the buffer reaches a size threshold.
The interface allows swapping to Redis, Kafka, or a dedicated time-series
store later without changing any caller. This is for **non-critical** data
(analytics, progress) where losing the last few seconds on a crash is
acceptable — durable side effects use the transactional Oban path (see PubSub
below), not the buffer.

```elixir
defmodule MyApp.Buffers.AnalyticsBuffer do
  @moduledoc "ETS-backed write buffer; flushes to Postgres on a timer."
  use GenServer
  @behaviour MyApp.Buffer
  @flush_interval :timer.seconds(30)
  @table :analytics_buffer

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl MyApp.Buffer
  def write(key, value) do
    :ets.insert(@table, {{key, System.unique_integer()}, value})
    :ok
  end

  @impl MyApp.Buffer
  def flush, do: GenServer.call(__MODULE__, :flush)

  @impl GenServer
  def init(_) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    {:ok, schedule_flush(%{})}
  end

  @impl GenServer
  def handle_info(:flush, state), do: {:noreply, schedule_flush(do_flush(state))}

  @impl GenServer
  def handle_call(:flush, _from, state), do: {:reply, :ok, do_flush(state)}

  defp do_flush(state) do
    rows = :ets.tab2list(@table) |> Enum.map(&elem(&1, 1))
    :ets.delete_all_objects(@table)
    if rows != [], do: MyApp.Repo.insert_all(MyApp.AnalyticsEvent, rows)
    state
  end

  defp schedule_flush(state) do
    Process.send_after(self(), :flush, @flush_interval)
    state
  end
end
```

```elixir
# Context function stays clean — callers never know about the buffer
def update_progress(scope, resource_id, position) do
  MyApp.Buffers.ProgressBuffer.write(
    {scope.user.id, resource_id},
    %{position: position, updated_at: DateTime.utc_now()}
  )
end
```

**At scale:** when a single GenServer + ETS can't keep up — you need
backpressure, concurrent batchers, or partitioned processing — move the
ingestion pipeline to [Broadway](https://broadway.hexdocs.pm/Broadway.html)
(GenStage under the hood). Broadway gives you bounded demand, automatic
batching, and rate limiting without hand-rolling flush logic. The context
function still just calls a `Buffer` impl
([contexts guide](https://hexdocs.pm/phoenix/contexts.html)) — the producer
behind it changes, callers don't.

### Never insert analytics events one at a time

Analytics events are append-only and high volume. Always batch them:

```elixir
# ❌ WRONG — one insert per event in the hot path
def record_view(scope, resource_id) do
  Repo.insert(%AnalyticsEvent{...})
end

# ✅ CORRECT — buffer and batch flush
def record_view(scope, resource_id) do
  MyApp.Buffers.AnalyticsBuffer.write(
    :resource_view,
    %{organization_id: scope.organization.id, user_id: scope.user.id,
      resource_id: resource_id, occurred_at: DateTime.utc_now()}
  )
end
```

### Separate read and write paths

Structure context functions so that reads can be routed to a replica and
writes go to the primary. Don't mix reads and writes in a single function
unless transactional consistency is actually required.

```elixir
# ✅ CORRECT — pure read, can run against a replica
def list_items(scope, opts \\ []) do
  Item
  |> where(organization_id: ^scope.organization.id)
  |> where([i], is_nil(i.deleted_at))
  |> order_by(desc: :inserted_at)
  |> Pagination.paginate(opts)
end

# ✅ CORRECT — pure write, must hit primary
def create_item(scope, attrs) do
  # ...
end

# ❌ AVOID — mixed read+write that forces primary for everything
def create_item_and_return_catalog(scope, attrs) do
  {:ok, item} = do_create_item(scope, attrs)
  items = list_items(scope)  # this read is now on primary
  {:ok, item, items}
end
```

You don't need to implement read replicas now. But when you do, it should
be a routing change in the Repo layer, not a rewrite of context functions.

### Read replicas (optional scaling pattern)

Most apps run a single primary indefinitely. When read volume justifies it,
add `read_only: true` replica repos pointing at separate hosts and route reads
to them — a config change, consistent with the "routing change, not a rewrite"
stance above
([Ecto replicas guide](https://ecto.hexdocs.pm/replicas-and-dynamic-repositories.html)):

```elixir
# Define replica repos
for repo <- [MyApp.Repo.Replica1, MyApp.Repo.Replica2] do
  defmodule repo do
    use Ecto.Repo, otp_app: :my_app, adapter: Ecto.Adapters.Postgres, read_only: true
  end
end

# config/runtime.exs — same database, different hosts
config :my_app, MyApp.Repo.Replica1, url: System.get_env("REPLICA1_URL")
config :my_app, MyApp.Repo.Replica2, url: System.get_env("REPLICA2_URL")
```

```elixir
# Pick a replica for reads; writes stay on MyApp.Repo
def replica, do: Enum.random([MyApp.Repo.Replica1, MyApp.Repo.Replica2])

def list_items(scope, opts \\ []) do
  Item
  |> where(organization_id: ^scope.organization.id)
  |> replica().all()
end
```

In tests there are no real replicas — point them at the primary with
`:default_dynamic_repo` (Ecto >= 3.9) so the sandbox connection is shared:

```elixir
# test setup
MyApp.Repo.Replica1.put_dynamic_repo(MyApp.Repo)
MyApp.Repo.Replica2.put_dynamic_repo(MyApp.Repo)
```

### Index strategy

Every query that runs in the end-user hot path must be backed by an index. At
minimum, every tenant-scoped table needs:

- Index on `tenant_id` (required by multi-tenancy rules if applicable)
- Composite index on `[tenant_id, <sort_column>]` for listing queries
- Composite index on `[tenant_id, user_id]` for user-scoped lookups
  (favorites, activity, progress, subscriptions)

When adding a new query to a context function, check `EXPLAIN ANALYZE` in
dev to verify it's using an index. Log any sequential scan on a table with
more than 1000 rows.

---

## LiveView Connections: Minimize Persistent State

### End-user-facing pages should minimize LiveView connections

At high concurrency, a full LiveView on every page means a persistent
WebSocket connection per user. Each connection holds a BEAM process with
socket assigns in memory.

**Strategy: Islands Architecture**

End-user-facing pages should render as static server-rendered HTML by default.
Add interactivity at the lowest cost tier that satisfies the requirement:

| Need | Tool | Persistent WebSocket? |
|---|---|---|
| Toggle/show-hide, class swap, dispatch a client event | stateless function component + [`Phoenix.LiveView.JS`](https://hexdocs.pm/phoenix_live_view/Phoenix.LiveView.JS.html) | **No** |
| Small client-side JS bridge (copy-to-clipboard, chart) | [colocated hook](https://hexdocs.pm/phoenix_live_view/Phoenix.LiveView.ColocatedHook.html) on a static element | **No** |
| Server round-trips, live data, server-held state | true LiveView island via `live_render/3` | **Yes** (one per island) |

Reserve `live_render/3` for islands that genuinely need a server connection
(the interactive player + progress, a live comment feed). Everything that's
just DOM manipulation should stay client-side with `JS`/colocated hooks
([LiveView 1.1 release](https://www.phoenixframework.org/blog/phoenix-liveview-1-1-released)).

```heex
<%!-- Static page shell — no persistent WebSocket for these bits --%>
<main>
  <h1>{@resource.title}</h1>

  <%!-- Stateless interaction: JS-only, no WebSocket --%>
  <button phx-click={JS.toggle(to: "#details")}>Toggle details</button>
  <div id="details" hidden>{@resource.description}</div>

  <%!-- True LiveView island — persistent WebSocket, only where needed --%>
  {live_render(@conn, MyAppWeb.Viewer.PlayerComponent,
    session: %{"resource_id" => @resource.id, "organization_id" => @scope.organization.id})}
</main>
```

This dramatically reduces the number of persistent connections while
preserving interactivity where it matters.

**What should be full-page LiveView:**
- Internal/admin dashboard (always — low concurrent users, high interactivity)
- User account/settings page (low traffic)
- Pages with heavy two-way interaction (moderate traffic, high interactivity)

**What should be static with LiveView islands:**
- Homepage / browse pages (high traffic, mostly read-only)
- Detail/player pages (high traffic, only specific controls are interactive)
- Search results (high traffic, mostly read-only)

### LiveView Collections: Use Streams Instead of Assigns

Holding a collection in `socket.assigns` keeps every item in server memory for
the connection's lifetime. **Streams** keep the collection in the client's DOM
instead, so the server holds (almost) nothing
([LiveView docs](https://hexdocs.pm/phoenix_live_view/Phoenix.LiveView.html),
[streams dev blog](https://fly.io/phoenix-files/phoenix-dev-blog-streams/)).
Streams are the generator default in Phoenix 1.8 (introduced LiveView
0.18+/Phoenix 1.7+).

Use streams for **large or unbounded** collections (activity feeds, search
results, chat). **Bounded** paginated lists (`per_page: 25`) can stay in assigns
— streams add no value there.

The API:

- `stream/3,4` — initialize a stream (`reset: true` replaces the collection)
- `stream_insert/3,4` — insert **and** update (matches on `dom_id`; there is
  **no** `stream_update`)
- `stream_delete/3` — remove an item
- `stream_configure/3` — configure (e.g. `:limit`) before first `stream/3`

```elixir
# ❌ AVOID — whole collection lives in server memory for the connection's life
def mount(_params, _session, socket) do
  {:ok, assign(socket, posts: Content.list_posts(socket.assigns.current_scope))}
end

# ✅ CORRECT — collection lives in the client DOM, not server assigns
def mount(_params, _session, socket) do
  posts = Content.list_posts(socket.assigns.current_scope)
  {:ok, stream(socket, :posts, posts)}
end

def handle_info({:post_created, post}, socket) do
  {:noreply, stream_insert(socket, :posts, post, at: 0)}
end

def handle_info({:post_deleted, post}, socket) do
  {:noreply, stream_delete(socket, :posts, post)}
end
```

Render keyed by the stream's `dom_id`:

```heex
<tbody id="posts" phx-update="stream">
  <tr :for={{dom_id, post} <- @streams.posts} id={dom_id}>
    <td>{post.title}</td>
  </tr>
</tbody>
```

Streams **supersede** the old `temporary_assigns` + `phx-update="append"`
pattern for collections — prefer streams in new code.

**Capped feed with `:limit`.** A live feed that should show only the latest N
items caps the stream with `:limit` and prunes on the client. A **positive**
limit keeps items from the **head** of the stream, a **negative** limit keeps
the **tail** — so the sign must match where you insert: prepend with `at: 0`
keeps the head (positive limit), append with `at: -1` keeps the tail (negative
limit). Mismatching them prunes the items you just inserted.

```elixir
def mount(_params, _session, socket) do
  events = Activity.recent_events(socket.assigns.current_scope, per_page: 50)
  {:ok, stream(socket, :events, events, limit: 50)}
end

def handle_info({:new_event, event}, socket) do
  # Prepend the newest at the head (at: 0) and keep the head (positive limit),
  # so the just-inserted item is never the one pruned.
  # RE-PASS :limit on every stream_insert/4 — it is not remembered.
  {:noreply, stream_insert(socket, :events, event, at: 0, limit: 50)}
end
```

Caveats:

- **`:limit` prunes on the client**, not the server. Re-pass it on **every**
  `stream_insert/4`; it is not remembered between calls.
- `:limit` is **not** applied on the initial mount render — only as
  inserts/updates arrive. Cap the initial collection yourself (here,
  `per_page: 50`).

### Keep socket assigns lean

Every byte in `socket.assigns` is held in memory for the lifetime of the
connection. Never preload entire association trees into assigns. Load the
minimum needed for render, and fetch on demand for interactions. For large or
unbounded collections, use a **stream** (above) rather than assigns; bounded
paginated lists like the example below can stay in assigns.

```elixir
# ❌ WRONG — loads everything into memory
def mount(_params, _session, socket) do
  items = Content.list_items(socket.assigns.current_scope)
            |> Repo.preload([:tags, :collections, :analytics_events])
  {:ok, assign(socket, items: items)}
end

# ✅ CORRECT — minimal data, load details on demand
def mount(_params, _session, socket) do
  %{results: items} = Content.list_items(socket.assigns.current_scope,
    per_page: 25, fields: [:id, :title, :slug])
  {:ok, assign(socket, items: items)}
end
```

---

## Caching: The Layer Between Users and Postgres

### All frequently-read, infrequently-written data goes through cache

If data is read on every page load but only changes when an admin makes
an edit, it must be cached.

**What to cache (examples):**
- Tenant resolution (slug → tenant) — TTL: 5 minutes
- Theme/branding per tenant — until invalidated
- Layout/row configuration per tenant — until invalidated
- Content catalog metadata — TTL: 1 minute
- Subscription or entitlement status per user+tenant — TTL: 1 minute
- Feature flags per tenant — TTL: 5 minutes

**What NOT to cache:**
- Per-user progress or position (changes constantly)
- Analytics events (write-only)
- Audit logs (write-only)
- Real-time connection counts (derived from live processes, not DB)

### Choosing a cache backend

Pick the simplest backend that meets the need; escalate only when you outgrow it
([Cachex in Elixir](https://blog.appsignal.com/2024/03/05/powerful-caching-in-elixir-with-cachex.html)):

| Backend | When | Notes |
|---|---|---|
| Raw **ETS** | Small metadata, single node | Zero deps; **copies large terms into the caller** on read, so keep values small. No built-in TTL. |
| **Cachex** `~> 3.6` | Single node, need TTL / fallback / stampede protection | Community default for in-process caching; fallback warms misses, courier dedupes concurrent fills. |
| **Redis** | Multi-node only | Shared state across the cluster. One valid option once a single node's cache can't be authoritative. |

Event-driven invalidation (below) is the **primary** consistency mechanism;
TTL is a backstop for anything a missed event would leave stale.

### Cache implementation

Use a `MyApp.Cache` behaviour with a default ETS/Cachex implementation
(swappable to Redis at scale):

```elixir
defmodule MyApp.Cache do
  @callback fetch(key :: String.t(), opts :: keyword(), fallback :: fun()) ::
    term()
  @callback invalidate(key :: String.t()) :: :ok
  @callback invalidate_pattern(pattern :: String.t()) :: :ok
end
```

Context functions read through the cache transparently:

```elixir
def get_theme(scope) do
  org_id = scope.organization.id
  Cache.fetch("theme:#{org_id}", ttl: :timer.minutes(5), fn ->
    Repo.get_by(Theme, organization_id: org_id)
  end)
end
```

### Cache invalidation via events

When an admin updates a cached resource, the event broadcast triggers
cache invalidation across the cluster:

```elixir
defmodule MyApp.Events.CacheSubscriber do
  def handle_event(_scope, {:theme_updated, theme}) do
    Cache.invalidate("theme:#{theme.tenant_id}")
  end

  def handle_event(_scope, {:layout_updated, layout}) do
    Cache.invalidate("layout:#{layout.tenant_id}")
  end

  def handle_event(_scope, {:tenant_updated, tenant}) do
    Cache.invalidate("tenant:slug:#{tenant.slug}")
    Cache.invalidate("tenant:domain:#{tenant.custom_domain}")
  end
end
```

Since Phoenix PubSub propagates across all nodes in the cluster, cache
invalidation on one node invalidates on all nodes.

---

## PubSub: Only Broadcast What Multiple Processes Need

### Rules for PubSub usage

**DO broadcast:**
- Content changes (item published, layout reordered) — admins and end users
  on the same tenant need to see updates
- Subscription/entitlement events (new subscriber, cancellation) — admin
  dashboard real-time counters
- Admin actions (item deleted, settings changed) — other admins in
  the same tenant see the change live
- Cache invalidation signals

**DO NOT broadcast:**
- Per-user progress or position updates — single-session state, no other
  process cares
- Analytics events — write to buffer, not PubSub
- Per-user UI state — scroll position, expanded accordions, filter selections
- Heartbeats or "still active" pings

### Delivery guarantee: PubSub is at-most-once

[`Phoenix.PubSub`](https://hexdocs.pm/phoenix_pubsub/Phoenix.PubSub.html)
delivers **at most once**. A message is dropped if the subscriber crashes mid-
handle, a node fails, or a process restarts after the broadcast. That's fine for
**lossy-OK** consumers — cache invalidation, live UI updates, presence — where a
missed message self-heals on the next event or page load.

For **business-critical** side effects (audit log, billing webhooks, anything
that must happen exactly once), do **not** rely on the broadcast → subscriber
hop — it's at-most-once even if the subscriber then enqueues Oban. Make the
effect durable **at the source**: enqueue the Oban job (or insert an outbox row)
**inside the same transaction** that commits the write. That gives at-least-once
delivery; idempotency keys dedupe replays
([event handling in Elixir](https://mkaszubowski.com/2021/01/09/elixir-event-handling.html),
[PubSub listener patterns](https://elixirforum.com/t/whats-the-best-pattern-for-a-pubsub-event-listener-genserver-seems-like-the-wrong-choice/35703)).

```elixir
# ✅ CORRECT — durable side effect enqueued transactionally with the write
def publish_post(scope, attrs) do
  Ecto.Multi.new()
  |> Ecto.Multi.insert(:post, Post.changeset(%Post{}, attrs))
  |> Oban.insert(:audit, fn %{post: post} ->
    AuditWorker.new(%{org_id: scope.organization.id, post_id: post.id})
  end)
  |> Repo.transaction()
  # then broadcast the lossy-OK live-UI/cache event
end

# ❌ WRONG — audit work hangs off a PubSub subscriber: lost on the dropped hop
def handle_event(_scope, {:post_published, post}) do
  Oban.insert(AuditWorker.new(%{post_id: post.id}))  # broadcast was at-most-once
end
```

| Consumer | Lossy OK? | How |
|---|---|---|
| Cache invalidation, live UI, presence | Yes | PubSub subscriber |
| Audit log, billing, outbound webhooks | No | Oban enqueued in the write's transaction |

### Topic design

All PubSub topics must be scoped to the narrowest useful audience. Prefer
**hierarchical, two-part names** (`resource:id:subresource:id`) so a subscriber
can scope to exactly the slice it cares about:

```elixir
# ✅ Org-scoped — only processes interested in this org
"events:#{org_id}"

# ✅ Hierarchical resource-scoped — a specific room within an org
"org:#{org_id}:room:#{room_id}"

# ✅ User-scoped (resource vs. user topics are distinct audiences)
"user:#{user_id}:notifications"

# ✅ Admin-scoped — only admin dashboard processes for this org
"admin:#{org_id}"

# ❌ Global topic with high-frequency messages
"all_events"

# ❌ Per-user topic that nobody else subscribes to (single-session state)
"user:#{user_id}:progress"
```

If subscription happens through a Phoenix Channel, enforce authorization in the
[`join/3` callback](https://hexdocs.pm/phoenix/Phoenix.Channel.html) — it is the
security boundary. A user may only join `org:#{org_id}:...` topics for an org
their scope grants. Bare `Phoenix.PubSub.subscribe/2` has no such gate, so never
expose user-controlled topic strings to it.

### At scale

If PubSub over Erlang distribution becomes a bottleneck (every message goes
to every node), the migration path is:

1. Move high-volume topics to Redis PubSub (Phoenix.PubSub.Redis adapter)
2. Keep low-volume topics on native Erlang distribution
3. Or: route PubSub messages through a dedicated message broker (NATS, RabbitMQ)

This is a configuration change in the PubSub adapter, not a code change,
as long as you follow the topic design rules above.

---

## Background Jobs: Separate by Criticality

### Queue hierarchy

```elixir
config :my_app, Oban,
  queues: [
    critical: 10,    # Subscription changes, payment processing
    default: 20,     # Webhook delivery, notifications, email
    external: 10,    # External service webhook processing (media provider, payment provider, etc.)
    bulk: 5,         # Analytics aggregation, progress flushes, exports
    imports: 3       # Migration/import jobs
  ]
```

### Rules

- **Never put high-volume work in `critical` or `default` queues.** Analytics
  flushes, progress batch writes, and data exports go in `bulk`.
- **Payment-related jobs go in `critical`.** A queue backlog in analytics
  must never delay a subscription activation or payment confirmation.
- **Tag every job with the tenant identifier** (see architecture-decisions.md).
  This enables per-tenant monitoring and future fair-scheduling.
- **Set timeouts per queue.** Critical jobs should time out quickly and retry
  fast. Bulk jobs can run longer with slower retries.

### Concurrency and backpressure

Set per-queue concurrency by criticality (the integers in the `queues:` config
above) and **monitor enqueue rate vs. process rate** — a queue whose depth grows
unbounded is under-provisioned or starved. Note the OSS vs. Pro limit semantics
([Oban](https://github.com/oban-bg/oban), [Oban Pro](https://oban.pro/)):

- **OSS:** queue concurrency limits are **per node** — effective concurrency is
  the limit × number of nodes.
- **Pro:** global limits and rate limits are enforced **cluster-wide**.

To stop one tenant from starving others within a shared queue, **partition** by
the tenant/org id (Pro's partitioned rate limiting, or separate queues) so a
bulk import for one org can't consume all slots. Every job already carries its
scope/org id in args, which makes this partitioning possible.

### At scale

If Oban's Postgres-backed queue becomes a bottleneck (millions of jobs per
hour), the migration path is Oban Pro with SmartEngine (partitioned queues,
rate limiting per tenant) or moving high-volume queues to a dedicated job
processor (Redis-backed or a custom GenStage pipeline).

The Oban Worker interface stays the same. Only the queue configuration changes.

---

## Rate Limiting: Per-Tenant Protection

### Every external-facing route needs rate limiting

A misbehaving tenant, a bot, or an attack on one tenant must not affect
other tenants.

### Implementation

Build a rate limit plug now, even if the limits are generous:

```elixir
defmodule MyAppWeb.Plugs.RateLimit do
  @moduledoc """
  Token bucket rate limiter. Configurable per route and per tenant.
  Default implementation uses ETS. Swappable to Redis at scale.
  """

  def init(opts), do: opts

  def call(conn, opts) do
    bucket = Keyword.fetch!(opts, :bucket)
    limit = Keyword.get(opts, :limit, 100)
    period = Keyword.get(opts, :period, :timer.minutes(1))
    key = build_key(conn, Keyword.get(opts, :key, :ip))

    case check_rate(bucket, key, limit, period) do
      :ok -> conn
      :rate_limited ->
        conn
        |> put_resp_header("retry-after", to_string(div(period, 1000)))
        |> send_resp(429, "Rate limit exceeded")
        |> halt()
    end
  end

  defp build_key(conn, :ip), do: client_ip(conn)
  defp build_key(conn, :tenant_id), do: conn.assigns[:current_scope].organization.id
  defp build_key(conn, :user_id), do: conn.assigns[:current_scope].user.id

  # Behind a proxy/LB, conn.remote_ip is the proxy. Trust X-Forwarded-For
  # only when the edge is trusted (e.g. via a RemoteIp plug upstream).
  defp client_ip(conn) do
    case Plug.Conn.get_req_header(conn, "x-forwarded-for") do
      [fwd | _] -> fwd |> String.split(",") |> List.first() |> String.trim()
      [] -> to_string(:inet.ntoa(conn.remote_ip))
    end
  end
end
```

This hand-rolled ETS token bucket is a **valid minimal option** for a single
node — not an anti-pattern. The `hammer_plug` library was
[EOL'd 2024-12-20](https://github.com/ExHammer/hammer) precisely because rolling
your own plug is trivial.

**Off-the-shelf alternative: Hammer 7.x.** If you'd rather not maintain the
bucket logic, [Hammer](https://github.com/ExHammer/hammer) `~> 7.0` is one valid
option. Define a limiter, supervise it, and wrap it in a function-plug
([Hammer docs](https://hexdocs.pm/hammer/1.0.0/index.html)):

```elixir
defmodule MyApp.RateLimiter do
  use Hammer, backend: :ets
end

# in your supervision tree
children = [{MyApp.RateLimiter, [clean_period: :timer.minutes(1)]}]
```

```elixir
defmodule MyAppWeb.Plugs.HammerRateLimit do
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, opts) do
    key = "#{opts[:bucket]}:#{conn.assigns.current_scope.organization.id}"

    case MyApp.RateLimiter.hit(key, opts[:period], opts[:limit]) do
      {:allow, _count} ->
        conn

      {:deny, retry_after_ms} ->
        conn
        |> put_resp_header("retry-after", to_string(div(retry_after_ms, 1000)))
        |> send_resp(429, "Rate limit exceeded")
        |> halt()
    end
  end
end
```

### Suggested limits (generous starting point)

| Route scope | Key | Limit | Period |
|---|---|---|---|
| Public/end-user pages | `tenant_id + ip` | 200 req | 1 minute |
| Public/end-user API | `tenant_id + user_id` | 100 req | 1 minute |
| Webhook receivers | `ip` | 500 req | 1 minute |
| Admin pages | `tenant_id + user_id` | 300 req | 1 minute |
| Super admin | `user_id` | 300 req | 1 minute |
| Auth endpoints | `ip` | 10 req | 1 minute |

### At scale

The ETS-based rate limiter works on a single node. In a multi-node cluster,
each node has its own counters — effective limits are multiplied by the number
of nodes. For strict enforcement at scale, move to a shared Redis counter with
`INCR` + `EXPIRE`. The plug interface stays the same.

For distributed enforcement off the shelf, [Hammer](https://github.com/ExHammer/hammer)
ships a maintained Redis backend (swap `backend: :ets` for the Redis backend —
the limiter and plug stay the same). Note that
[PlugAttack](https://github.com/michalmuskala/plug_attack) (a nice rule-DSL
option for single-node throttling/blocklisting) does **not** ship a Redis
backend, so it doesn't give cluster-wide limits on its own.

---

## Tenant Isolation Under Load

### One tenant must never degrade another tenant's experience

This is the most important scalability principle for multi-tenant SaaS.
If your app is not multi-tenant, apply the same principle to any shared
resource (queues, cache, DB connection pool).

**Database:** If one tenant has a large dataset, their listing queries
shouldn't slow down tenants with smaller datasets. Ensure all queries are
indexed and paginated. Consider per-tenant query timeouts.

**Background jobs:** If one tenant triggers a bulk import, their Oban jobs
shouldn't starve other tenants' webhook processing. Use queue separation
and consider per-tenant job concurrency limits.

**Cache:** One tenant's cache invalidation storm (updating many records at
once) shouldn't evict another tenant's cached data. Use tenant-namespaced
cache keys so eviction is scoped.

**Connections:** One tenant's users shouldn't consume all available LiveView
connections. The main lever is keeping public-facing pages lightweight
(islands architecture) so each connection uses minimal resources.

**Rate limiting:** Already covered above — per-tenant rate limits prevent
one tenant from monopolizing resources.

---

## Checklist for New Features

When building a new feature, verify:

- [ ] Context functions take `scope` as their first argument
- [ ] High-frequency writes use a buffer, not direct Repo inserts
- [ ] End-user-facing pages minimize persistent LiveView connections
- [ ] Large/unbounded LiveView collections use streams, not assigns
- [ ] Socket assigns contain only the minimum data needed for render
- [ ] Business-critical side effects are enqueued in the write's transaction (not from a PubSub subscriber)
- [ ] Frequently-read data goes through the cache layer
- [ ] Cache keys are tenant-namespaced for scoped invalidation
- [ ] PubSub is only used for broadcast-worthy events, not per-user state
- [ ] PubSub topics are scoped to the narrowest useful audience
- [ ] Background jobs are in the correct queue by criticality
- [ ] Database queries in the end-user hot path are indexed
- [ ] Rate limiting is applied to any new external-facing route
- [ ] Read and write paths are separable for future read-replica support
- [ ] One tenant's usage cannot degrade another tenant's experience
