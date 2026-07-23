# Scalability

Load this file when building any feature that handles end-user-facing traffic,
writes high-frequency data, or introduces new database queries. Build every
feature assuming the platform will eventually serve a large number of concurrent
users.

We don't need to handle that load today. We need to make decisions today that
don't prevent us from handling it later.

> **Baseline:** Ruby 3.3+ · modular Sinatra (`class App < Sinatra::Base`, Puma) ·
> Sequel ORM · **SQLite** (WAL journal mode, `busy_timeout` set, replicated to S3
> by Litestream). Redis for cache / buffers / pub-sub. Sidekiq only when durable
> async is needed. Domain logic in service objects; request context via a
> `Current` module.

**Maturity tags** used below: `[Template default]` ships in the Sinatra scaffold ·
`[Stable]` mature, widely-run gem · `[Optional]` reach for it only when you
outgrow the default. Gem pins are **loose** (`~> X.Y`) — track the latest
compatible release.

> **Read `.claude/database.md` first.** SQLite is a **single-writer** engine:
> exactly one write transaction touches the file at a time, everything else waits.
> That one fact drives most of this doc — buffers, batching, transaction length,
> and the honest "no read replicas" reality in §2.

---

## Guiding Principle

External services (a media provider, a payment provider, an object store) handle
their respective heavy lifting. Your infrastructure handles everything around
them: authentication, session management, page rendering, event tracking,
activity feeds, and the admin dashboard. Design every feature knowing
high-concurrency users will hit your one SQLite file, your realtime connections,
your caches, and your background job queues.

### Request context: a `Current` module, not globals

Domain logic lives in **service objects** (and Sequel datasets), never inline in
routes. The current actor and tenant boundary travel via a **`Current` module**
(thread/fiber-local, plain Ruby — there is no `ActiveSupport::CurrentAttributes`
here), not ad-hoc thread-globals or method-threaded `scope` args.

```ruby
# app/current.rb — thread/fiber-local request context, plain Ruby
module Current
  class << self
    def user       = store[:user]
    def user=(u)   ; store[:user] = u    ; end
    def account    = store[:account]
    def account=(a); store[:account] = a ; end
    def reset!     ; Thread.current[:current] = nil; end

    private

    def store = (Thread.current[:current] ||= {})
  end
end
```

```ruby
# app.rb — set once per request, always reset
class App < Sinatra::Base
  before do
    Current.reset!
    Current.account = resolve_account       # from subdomain / session
    Current.user    = authenticated_user
  end

  after { Current.reset! }                   # never leak context across requests
end
```

The **tenant boundary is explicit** and every tenant-scoped query filters on it
(see Tenant Isolation, below). Scoping is a *data boundary* (which rows a query
may touch) — keep it distinct from *authorization* (which actions a user may
perform); gate actions with the plain-Ruby policy objects in `app/policies/`,
separately.

---

## 1. Protect SQLite from the Hot Path

> **SQLite is a single writer.** Every `INSERT`/`UPDATE`/`DELETE` takes an
> exclusive write lock on the whole database file; only one write transaction
> proceeds at a time. WAL mode lets **readers run concurrently with the one
> writer**, but writers still serialize. A blocked writer waits up to
> `busy_timeout` and then raises `SQLITE_BUSY`. Therefore: **keep write
> transactions short, and never do high-frequency row-by-row writes on the hot
> path.** Batch them.

### Never write high-frequency data directly to the DB, row by row

Any operation firing more than once per user per minute must not do a per-event
`INSERT`/`UPDATE`. On SQLite this is not a nicety — N per-event writes take the
single write lock N times and pile up against `busy_timeout`, stalling *every*
other writer in the app. Batch it into **one** short transaction.

**High-frequency examples:** progress/position tracking, analytics/activity
events (play, pause, seek, complete), heartbeat pings, view/like counters.

**Batching strategies:**

| Strategy | Use when | Mechanism |
|---|---|---|
| **Buffer → flush** | Append-only events you can lose a few seconds of on crash | Push to Redis (list); a recurring job drains and does one `multi_insert` |
| **Counters in Redis** | Monotonic counts (views, likes, plays) | `INCR`/`HINCRBY` in Redis; a periodic job reconciles to SQLite |
| **Bulk insert** | You already hold N rows in memory | Sequel `dataset.multi_insert(rows)` — one short write transaction, one lock |

### Provide a buffer abstraction

Callers never know whether a write was buffered or direct — same interface. The
default impl is Redis-backed; the interface lets you swap to an in-process buffer
(single Puma worker) or a stream store later without touching callers.

```ruby
# app/buffer.rb — one queue method, one flush method.
module MyApp
  module Buffer
    def write(key, value); raise NotImplementedError; end  # enqueue, return :ok
    def flush; raise NotImplementedError; end               # drain → bulk insert
  end
end

# Default Redis impl. [Stable] gem: redis ~> 5.0
module MyApp
  module Buffers
    module AnalyticsBuffer
      extend MyApp::Buffer
      KEY = "buffer:analytics".freeze

      def self.write(_key, value)
        MyApp.redis.rpush(KEY, value.to_json)
        :ok
      end

      def self.flush
        rows = []
        while (raw = MyApp.redis.lpop(KEY))
          rows << JSON.parse(raw, symbolize_names: true)
        end
        return :ok if rows.empty?
        # ✅ one short write transaction, one lock — not N inserts
        DB.transaction { DB[:analytics_events].multi_insert(rows) }
        :ok
      end
    end
  end
end
```

```ruby
# ❌ WRONG — one insert (one write lock) per event on the hot path
def record_view(resource)
  AnalyticsEvent.create(account_id: Current.account.id, resource_id: resource.id)
end

# ✅ CORRECT — buffer; a recurring job flushes in one batched transaction
def record_view(resource)
  MyApp::Buffers::AnalyticsBuffer.write(:resource_view, {
    account_id: Current.account.id, user_id: Current.user.id,
    resource_id: resource.id, occurred_at: Time.now
  })
end
```

**Single-process shortcut.** With SQLite you often run **one** Puma worker with
several threads on a single droplet. In that setup an in-process,
thread-safe buffer (e.g. a `Concurrent::Array` drained by a background thread)
avoids Redis entirely. The moment you run more than one Puma worker or node, the
in-process buffer stops sharing state — move it to Redis. Keep the `MyApp::Buffer`
interface so that swap is a one-line config change.

**Flush job.** Drive the drain on a short interval. A recurring Sidekiq job
(`sidekiq-cron` / `sidekiq-scheduler`, `[Optional]`) calls
`MyApp::Buffers::AnalyticsBuffer.flush`; cron granularity is one minute, so for a
tighter 30s cadence use a scheduler gem or a tiny dedicated flusher loop process.

**Counters:** never `UPDATE counters SET n = n + 1` per event. On SQLite that
takes the whole-database write lock on every single event — the worst possible hot
path. `HINCRBY` in Redis; a recurring job reconciles.

```ruby
MyApp.redis.hincrby("views:account:#{Current.account.id}", resource.id, 1)  # hot path
# recurring job: read the hash, one batched UPDATE per row inside a short tx, reset
```

> **Rule:** any write firing >1×/user/minute goes through a buffer or Redis
> counter. Losing the last few seconds on a crash is acceptable for analytics;
> business-critical effects use the durable job path (§6/§7), not the buffer.

---

## 2. Separate Read and Write Paths (SQLite has no replicas)

**Be honest about the backend:** SQLite is a **single file on one droplet**.
There is **no read replica** — you cannot point reads at a second, queryable
database. Litestream streams the WAL to S3 (DO Spaces) for **disaster recovery
and point-in-time restore**, *not* for live read scaling; the S3 copy is a
restore target, not a queryable endpoint. This is the deliberate tradeoff of the
SQLite backend. See `.claude/database.md`.

**So how do you scale reads?** With the three levers SQLite actually gives you,
in this order:

1. **WAL concurrent reads** — in WAL mode, readers never block and are never
   blocked by the single writer. Your read concurrency comes from here for free.
2. **Caching** — put the frequently-read/rarely-written data in Redis (§5) so the
   read never touches the file at all.
3. **Tight indexes** — every hot-path read is an index scan, never a table scan
   (§3).

Adding a replica is **not** on the menu; don't design as if it were.

### Still keep reads and writes in separate methods

The read/write separation discipline from the Rails world still applies here — but
for a different reason. On SQLite it isn't about future replica routing; it's
about **transaction length**. A read folded into a write method lengthens the
write transaction, and a long write transaction holds the single writer lock and
blocks every other writer app-wide.

```ruby
# ✅ pure read — no transaction held, runs concurrently under WAL
def recent_notes
  Note.where(account_id: Current.account.id)
      .order(Sequel.desc(:created_at))
      .limit(25).all
end

# ❌ AVOID — read work padding the write transaction, holding the writer lock longer
def create_note_and_return_feed(attrs)
  DB.transaction do
    note = Note.create(attrs.merge(account_id: Current.account.id))  # write
    feed = recent_notes                                              # read — get it OUT of the tx
    [note, feed]
  end
end

# ✅ BETTER — commit the write fast, then read outside the transaction
def create_note_and_return_feed(attrs)
  note = DB.transaction { Note.create(attrs.merge(account_id: Current.account.id)) }
  [note, recent_notes]
end
```

> Keep writes in the shortest possible transaction and reads out of it. That's the
> SQLite equivalent of "replica-routable later" — the payoff is a writer lock that
> is held for microseconds, not milliseconds.

---

## 3. Indexing

Every query in the end-user hot path must be backed by an index. This matters
doubly on SQLite: an unindexed scan not only is slow, it lengthens any
transaction it runs inside, holding the writer lock.

| Table shape | Required index |
|---|---|
| Any tenant-scoped table | `account_id` |
| Listing query (sorted) | composite `[account_id, created_at]` |
| User-scoped lookup (favorites, progress, subs) | composite `[account_id, user_id]` |
| Lookup by slug/handle | `[account_id, slug]` (unique where appropriate) |

- **Composite tenant indexes lead with `account_id`** — it's in every `WHERE`.
- **Verify with `EXPLAIN QUERY PLAN`** in dev for each new hot-path query. Treat a
  `SCAN` on any table >1000 rows as a bug — you want `SEARCH … USING INDEX`.
- Add indexes in a Sequel migration.

```ruby
# db/migrate/00X_index_notes.rb
Sequel.migration do
  change do
    alter_table(:notes) do
      add_index [:account_id, :created_at]
    end
  end
end
```

```sql
EXPLAIN QUERY PLAN
SELECT * FROM notes WHERE account_id = 42 ORDER BY created_at DESC LIMIT 25;
-- want: SEARCH notes USING INDEX notes_account_id_created_at_index
-- bug:  SCAN notes
```

Run it from Sequel with `DB["EXPLAIN QUERY PLAN SELECT …"].all` or via the
`sqlite3` CLI.

---

## 4. Minimize Heavy Client Connections

This template defaults to **server-rendered ERB with minimal vanilla JS**, and
that's the cheaper path at scale: each persistent realtime connection (SSE or
websocket) **holds a Puma thread** from a bounded pool for its whole lifetime, so
spend them only where realtime is genuinely required. On a single-droplet SQLite
deployment that pool is your hard ceiling on concurrent long-lived connections —
guard it.

### Server-rendered first

| Need | Tool | Persistent connection? |
|---|---|---|
| Show/hide, toggles, small client behavior | small vanilla JS in `public/js/` on static HTML | **No** |
| Replace part of the page on a request | a normal form/`fetch` round-trip that re-renders an ERB partial | **No** (request/response) |
| Server pushes updates to many clients | **SSE** (or a light websocket) fed by Redis pub/sub | **Yes** (one Puma thread each) |

There is no Hotwire / Turbo / Stimulus / Action Cable in this stack — don't reach
for them. Reserve SSE / websocket subscriptions for genuinely realtime views
(live feed, presence). Static browse/detail/search pages render plain HTML — no
persistent connection.

### Keep payloads lean, kill N+1

```ruby
# ❌ N+1 — one query per note for its author
Note.where(account_id: Current.account.id).all.each { |n| n.author.name }

# ✅ eager-load the association (Sequel: separate preload query, not a JOIN)
Note.where(account_id: Current.account.id).eager(:author).limit(25).all
```

- Use `eager(:author)` for rendering a list; use `eager_graph(:author)` only when
  you must **filter or sort on** the association (it builds the JOIN).
- Never load entire association trees for a list view. Select only the columns you
  render: `Note.where(...).select(:id, :title, :slug)`.
- Paginate every list. Never render an unbounded collection — use the Sequel
  pagination extension.

```ruby
DB.extension(:pagination)
# every list method takes page + per_page (default 25, max 100)
page = Note.where(account_id: Current.account.id)
           .order(Sequel.desc(:created_at))
           .paginate(params[:page].to_i.clamp(1, ..), 25)
page.all          # this page's rows
page.pagination_record_count  # total, for the pager
```

---

## 5. Caching: The Layer Between Users and SQLite

Data read on every page load but written only on an admin edit must be cached —
and with SQLite this is your **primary** read-scaling lever (there's no replica to
offload to, §2). There is **no `Rails.cache` and no Solid Cache here.** Caching is
a small explicit wrapper over Redis (`app/cache.rb`); if you don't cache, you
memoize per request.

| Cache | Examples | Strategy |
|---|---|---|
| **Cache** | tenant resolution (slug→account), theme/branding, layout config, catalog metadata, feature flags, entitlement status | `MyApp::Cache.fetch` with TTL + invalidation on write |
| **Never cache** | per-user progress/position, analytics (write-only), audit logs (write-only), live connection counts | — |

### The cache wrapper

```ruby
# app/cache.rb — the only cache abstraction in this stack. [Stable] redis ~> 5.0
module MyApp
  module Cache
    def self.fetch(key, ttl: 300)
      if (raw = MyApp.redis.get(key))
        return JSON.parse(raw, symbolize_names: true)
      end
      value = yield
      MyApp.redis.set(key, value.to_json, ex: ttl)  # store JSON-safe data, not live objects
      value
    end

    def self.delete(key) = MyApp.redis.del(key)
  end
end
```

Redis stores strings, so cache **serializable data** (a row's column hash), never
a live `Sequel::Model`.

### Backend decision table

| Backend | When | Maturity |
|---|---|---|
| **In-process memoization** | Single Puma worker, per-request only; no cross-process sharing | `[Template default]` (plain Ruby) |
| **Redis** | Shared cache across Puma workers / nodes; you already run it for buffers/jobs | `[Stable]` (redis ~> 5.0) |
| **Memcached** | Pure volatile LRU, multi-node, simplest semantics | `[Optional]` |

```ruby
# read-through cache; invalidation on write is primary, TTL is the backstop
def account_theme
  MyApp::Cache.fetch("account:#{Current.account.id}:theme", ttl: 300) do
    Theme.where(account_id: Current.account.id).first&.values   # a plain hash
  end
end
```

### Cache rendered fragments manually (the Russian-doll equivalent)

There's no `<% cache %>` view helper here. Render an ERB partial to a string and
store it in Redis, keyed by the record's id **and** `updated_at` so the fragment
auto-expires the instant the record changes.

```ruby
def note_card_html(note)
  MyApp::Cache.fetch("note:#{note.id}:card:#{note.updated_at.to_i}", ttl: 3600) do
    erb :_note_card, layout: false, locals: { note: note }
  end
end
```

### Invalidate on write

The code that mutates the data busts its cache key right after the change commits —
in the service, or in a Sequel `after_commit` hook on the model so it can't be
missed.

```ruby
# in the service, after the write transaction commits:
DB.transaction { theme.update(theme_attrs) }
MyApp::Cache.delete("account:#{theme.account_id}:theme")

# or, so no call site can forget it — Sequel fires after_commit post-commit:
class Theme < Sequel::Model
  def after_commit
    super
    MyApp::Cache.delete("account:#{account_id}:theme")
  end
end
```

With Redis as a shared backend, one worker's `delete` is visible to every worker
and node. Per-process in-memory memoization is **not** shared — if you run more
than one Puma worker, cache anything that needs invalidation in Redis, not in a
process-local hash, or nodes will serve stale data.

---

## 6. Realtime / PubSub: Topic Design + the At-Most-Once Caveat

**This is the highest-value rule in this doc.** Broadcasts are **lossy**; jobs are
**durable**. Use each for what it guarantees. The transport here is **Redis
pub/sub feeding Server-Sent Events** (or a light websocket) — there is no Action
Cable / Turbo Streams.

### Broadcast only what multiple processes need

**DO broadcast** (lossy-OK, self-heals on next event/reload):
- Content changes (note published, layout reordered) — viewers on the same account
  see it update
- Admin-dashboard live counters (new subscriber, cancellation)
- Presence / live UI state shared across clients

**DO NOT broadcast:**
- Per-user progress/position (single-session state — nobody else cares)
- Analytics events (→ buffer, §1)
- Per-user UI state (scroll, open accordions, filters)
- Heartbeats

### The SSE endpoint (authorize before subscribing)

```ruby
# app/routes/streams.rb — authorize FIRST, then hold the connection open
get "/accounts/:id/notes/stream" do
  account = Account[params[:id].to_i]
  authorize!(:read, account)             # the security boundary — before any subscribe
  content_type "text/event-stream"

  stream(:keep_open) do |out|
    sub = MyApp.redis_subscriber          # a DEDICATED redis connection for pub/sub
    sub.subscribe("account:#{account.id}:notes") do |on|
      on.message { |_ch, msg| out << "data: #{msg}\n\n" }
    end
    out.callback { sub.unsubscribe }      # free the connection on client disconnect
  end
end
```

```ruby
# publish (lossy, at-most-once) AFTER the write commits:
MyApp.redis.publish("account:#{account_id}:notes",
                    { id: note.id, action: "created" }.to_json)
```

Every open SSE holds a Puma thread (§4) — reserve it for genuinely realtime views.

### Delivery guarantee: broadcasts are at-most-once

Redis pub/sub (and any broadcast) delivers **at most once**. A message is lost if
the subscriber crashes mid-handle, a node fails, or a process restarts after the
publish. Fine for cache invalidation, live UI, presence.

For **business-critical** side effects (audit log, billing webhooks, anything that
must happen exactly once), **do not** hang the effect off a pub/sub subscriber.
Make it durable at the source.

> **Enqueue-vs-commit — this stack has no shortcut, get it right:**
>
> Rails 8 could enqueue into Solid Queue *inside* the DB transaction because the
> queue lived in the same database. **This template has no DB-backed queue.**
> Sidekiq stores jobs in **Redis, which is not part of the SQLite transaction.**
> Enqueuing inside `DB.transaction` is the classic race: a worker can pick up the
> job before the row commits, or the job gets enqueued even after a rollback.
> There is no "same-database" escape hatch here — you have exactly two correct
> options:
>
> 1. **`DB.after_commit`** — register the enqueue to run after the transaction
>    commits. Avoids the race. (Tiny residual risk: if the process dies in the
>    window between commit and the block running, the enqueue is lost — acceptable
>    for most side effects.)
> 2. **Transactional outbox** — insert an `outbox` row *inside* the same SQLite
>    transaction, and a poller drains it into Sidekiq. SQLite is the source of
>    truth, giving true at-least-once. Use this for billing/webhooks.

```ruby
# ✅ CORRECT (option 1) — enqueue after the SQLite transaction commits
def publish_note(attrs)
  note = nil
  DB.transaction do
    note = Note.create(attrs.merge(account_id: Current.account.id))
    DB.after_commit { AuditJob.perform_async(Current.account.id, note.id) }
  end
  # after commit: the lossy-OK live-UI / cache-bust broadcast
  MyApp.redis.publish("account:#{Current.account.id}:notes",
                      { id: note.id, action: "created" }.to_json)
  note
end

# ✅ CORRECT (option 2) — durable outbox row commits atomically with the write
DB.transaction do
  note = Note.create(attrs.merge(account_id: Current.account.id))
  DB[:outbox].insert(topic: "audit",
                     payload: { account_id: Current.account.id, note_id: note.id }.to_json,
                     created_at: Time.now)
end
# a poller SELECTs unprocessed outbox rows → AuditJob.perform_async → marks them done

# ❌ WRONG — enqueue inside the tx: Redis isn't in the SQLite transaction
DB.transaction do
  note = Note.create(attrs)
  AuditJob.perform_async(note.id)   # worker may run before commit, or job survives a rollback
end
```

| Consumer | Lossy OK? | How |
|---|---|---|
| Cache invalidation, live UI, presence | Yes | Redis pub/sub → SSE broadcast |
| Audit log, billing, outbound webhooks | No | Sidekiq job enqueued via `DB.after_commit` or an outbox (§7) |

### Topic / channel design

Scope channels to the narrowest useful audience. Prefer hierarchical names.

```ruby
"account:#{account_id}:notes"           # ✅ account-scoped resource stream
"account:#{account_id}:room:#{room_id}" # ✅ hierarchical, specific slice
"user:#{user_id}:notifications"         # ✅ user-scoped (distinct audience)
"all_events"                            # ❌ global, high-frequency
"user:#{user_id}:progress"              # ❌ single-session state — don't broadcast
```

**Authorize in the stream route before you `subscribe`** — the route is the
security boundary. A user may only stream `account:#{id}:…` for an account their
`Current` boundary grants. Never interpolate user-controlled strings into a
channel name without an authorization check.

---

## 7. Background Jobs: Separate by Criticality

The template ships **no background jobs by default** — say so honestly. When you
need durable async, the answer is **Sidekiq** (Redis-backed); there is no Solid
Queue in this stack. For light, lose-on-restart async, a thread pool or
`sucker_punch` is the small-scale option; anything durable is Sidekiq.

### Queue hierarchy

```yaml
# config/sidekiq.yml — weighted queues, or run one process per criticality
:concurrency: 5
:queues:
  - [critical, 3]   # payments, subscription changes
  - [default,  2]   # webhooks, notifications, email
  - [bulk,     1]   # analytics flush, exports, imports
```

### Rules

- **Never put high-volume work in `critical` or `default`.** Buffer flushes (§1),
  analytics aggregation, and exports go in `bulk`.
- **Payment/subscription jobs go in `critical`.** A `bulk` backlog must never
  delay a payment confirmation. Consider a dedicated Sidekiq process for
  `critical` so a `bulk` slot can't starve it.
- **Tag every job with the tenant id** in its args — enables per-tenant monitoring
  and fair scheduling.
- **Pass ids, not objects, and re-establish `Current` inside the job.** Sidekiq
  args must be simple JSON types, and the job runs in a worker with no request
  context.
- **Enqueue durable side effects via `DB.after_commit` or an outbox** (§6), never
  inside the SQLite transaction.

```ruby
class AuditJob
  include Sidekiq::Job
  sidekiq_options queue: :default, retry: 5

  # always pass the tenant id; re-establish scope inside the job
  def perform(account_id, note_id)
    Current.account = Account[account_id]
    Notes::Audit.call(account_id: account_id, note_id: note_id)
  ensure
    Current.reset!
  end
end
```

### Backend decision

| Backend | When | Maturity |
|---|---|---|
| **Sidekiq** | Durable async; Redis-backed; mature ecosystem; the default choice here | `[Stable]` (sidekiq ~> 7.3) |
| **sucker_punch / thread pool** | In-process, lose-on-restart async at small scale | `[Optional]` |
| **sidekiq-cron / sidekiq-scheduler** | Recurring jobs (buffer flush §1, outbox drain §6) | `[Optional]` |

### At scale

Per-tenant fairness: partition by `account_id` so one tenant's bulk import can't
consume all slots (Sidekiq capsules / concurrency limits, or separate per-tenant
queues). Every job already carries its tenant id, which makes partitioning
possible. The worker interface stays the same; only queue config changes.

---

## 8. Rate Limiting: Per-Actor Protection

A misbehaving tenant, bot, or attack on one actor must not degrade others. Sinatra
ships **nothing** for this — Rack::Attack is the canonical answer.

### Rack::Attack — Rack middleware

[Rack::Attack](https://github.com/rack/rack-attack) `~> 6.7` `[Stable]` mounts as
middleware in front of `App`. Throttle by IP, account, or endpoint; return `429`
with `Retry-After`.

```ruby
# config.ru
require "rack/attack"
require_relative "config/rack_attack"
use Rack::Attack
run App
```

```ruby
# config/rack_attack.rb
class Rack::Attack
  # cluster-wide counters — back the store with Redis, not the in-memory default
  Rack::Attack.cache.store = Redis.new(url: ENV.fetch("REDIS_URL"))

  throttle("req/ip", limit: 200, period: 60) { |req| req.ip }

  throttle("api/account", limit: 100, period: 60) do |req|
    req.env["myapp.account_id"] if req.path.start_with?("/api")
  end

  throttle("logins/ip", limit: 10, period: 60) do |req|
    req.ip if req.path == "/login" && req.post?
  end

  self.throttled_responder = lambda do |req|
    match = req.env["rack.attack.match_data"]
    retry_after = match ? match[:period] : 60
    [429, { "Retry-After" => retry_after.to_s, "Content-Type" => "text/plain" },
     ["Rate limit exceeded\n"]]
  end
end
```

Back the store with **Redis** so counters are cluster-wide; the default in-memory
store gives per-node limits (effective limit × node count).

### No built-in fallback

There is no controller-level `rate_limit` macro here. For a single endpoint you
don't want to route through the middleware, a small `before` filter that
`INCR`s a Redis key with an `EXPIRE` and halts on overflow works — but prefer
Rack::Attack for anything cross-endpoint, blocklists, or fail2ban-style logic.

### Suggested starting limits (generous)

| Route scope | Key | Limit | Period |
|---|---|---|---|
| Public/end-user pages | `account + ip` | 200 | 1 min |
| Public/end-user API | `account + user` | 100 | 1 min |
| Webhook receivers | `ip` | 500 | 1 min |
| Admin pages | `account + user` | 300 | 1 min |
| Auth endpoints | `ip` | 10 | 1 min |

---

## 9. Tenant Isolation Under Load

**One tenant must never degrade another's experience** — the core multi-tenant
scalability rule. On SQLite it has extra teeth: because there is a **single
writer**, one tenant's slow or long write transaction blocks writes for *everyone*.
If your app isn't multi-tenant, apply this to any shared resource (queues, cache,
Puma thread pool).

| Vector | Risk | Mitigation |
|---|---|---|
| **Database (writes)** | One tenant's long/parallel write holds the single writer lock; others hit `SQLITE_BUSY` | Composite `[account_id, …]` indexes (§3), pagination, **keep transactions short**, batch writes (§1), tuned `busy_timeout` so blocked writers wait rather than fail |
| **Database (reads)** | One tenant's huge unindexed scan slows the file | Index every hot-path query; treat a `SCAN` as a bug (§3). Note: SQLite has **no `statement_timeout`** — tight indexes + pagination are the defense (see `.claude/database.md`) |
| **Background jobs** | One tenant's bulk import starves others' webhooks | Queue separation (§7) + per-tenant concurrency limits / partitioning |
| **Cache** | One tenant's invalidation storm evicts others' data | **Namespace keys by account** (`account:#{id}:theme`) so eviction is scoped |
| **Realtime** | One tenant's users consume all Puma threads | Keep public pages connection-free (§4); reserve SSE for realtime needs |
| **Rate limits** | One tenant monopolizes throughput | Per-account throttles (§8) |

```ruby
# ✅ tenant-namespaced cache key — scoped eviction
MyApp::Cache.fetch("account:#{Current.account.id}:layout") { ... }

# ✅ enforce the tenant boundary on every query via Current
Note.where(account_id: Current.account.id)
```

Every tenant-scoped query filters on `Current.account.id`. A shared dataset helper
on the model makes the boundary hard to omit:

```ruby
class Note < Sequel::Model
  dataset_module do
    def for_current_account
      where(account_id: Current.account.id)
    end
  end
end

Note.for_current_account.order(Sequel.desc(:created_at)).limit(25).all
```

Keep it as a *data boundary*, with authorization enforced separately by the policy
objects.

---

## Checklist for New Features

- [ ] Service objects own domain logic; routes stay thin (parse → call → render)
- [ ] Tenant boundary read from `Current`, not globals
- [ ] High-frequency writes go through a buffer or Redis counter, never row-by-row inserts
- [ ] Write transactions are short; bulk inserts use `dataset.multi_insert`, not a loop of `create`
- [ ] Reads are kept out of write transactions (short writer lock; there are no replicas to route to)
- [ ] Every hot-path query has a composite `[account_id, …]` index, verified with `EXPLAIN QUERY PLAN` (no `SCAN`)
- [ ] List views eager-load (`eager`) and paginate — no N+1, no unbounded loads
- [ ] Public pages render server HTML + minimal JS; SSE/websocket connections reserved for realtime
- [ ] Frequently-read/rarely-written data goes through `MyApp::Cache` (Redis) with invalidation on write
- [ ] Cache keys are account-namespaced
- [ ] Broadcasts carry only lossy-OK UI/cache events; business-critical effects enqueue via `DB.after_commit` or an outbox (never inside the transaction — Sidekiq lives in Redis, not the DB)
- [ ] Channels/topics are narrowly scoped and authorized in the stream route before subscribing
- [ ] Jobs are in the right queue by criticality, carry the tenant id, and re-establish `Current`
- [ ] Rate limiting (Rack::Attack, Redis-backed) covers every external-facing route
- [ ] One tenant's usage cannot degrade another's — especially the single writer (short transactions, batching, `busy_timeout`)
