# Architecture Decisions

Load this file when creating a new model/migration, a service object, or any
system infrastructure. These are decisions made early to avoid costly retrofits
later. Follow them in all new code.

> **Baseline:** Ruby 3.3+ · modular Sinatra (`class App < Sinatra::Base`, booted by
> Puma via `config.ru`) · Sequel ORM · SQLite (WAL journal, **one writer at a
> time**, replicated to S3 by Litestream) · ERB views.
> Domain logic in service objects returning `dry-monads` Results; request context
> via a thread-local `Current` module; authorization via plain-Ruby policy objects.
> Storage/engine specifics live in `.claude/database.md`.

| Topic | Sinatra + Sequel + SQLite |
|-------|---------------------------|
| Result type | `dry-monads` (`Success` / `Failure([:tag, …])`) or hand-rolled |
| Audit log | an `audit_logs` table, written by the service after commit |
| Soft delete | hand-rolled `deleted_at` + a Sequel dataset scope (no `discard`) |
| Pagination | Sequel `.limit`/`.offset` (default 25, max 100) |
| Side effects | called directly after commit (inline; Sidekiq for slow/external) |
| Idempotency keys | deterministic key persisted in an `idempotency_keys` table |
| Feature flags | a `flags` table (hand-rolled, no Flipper) |
| Request context | a thread/fiber-local `Current` module |
| Job tenant id | Sidekiq job arg (only if a job system is added) |
| Data export | single tenant-scoped service object |

---

## 1. Result / Tagged-Error Pattern

The principle: **expected, recoverable outcomes are values the caller branches on,
not exceptions raised for control flow.** Not found, invalid input, over a plan
limit — these are ordinary results, and `raise` is reserved for the truly
exceptional (programmer error, unreachable state, infrastructure down).

This template's **default** for surfacing those outcomes is a tagged Result: the
Result carries a tagged error so the caller knows the failure *kind* without
inspecting a string, and it prepares the domain layer for a future public API
without a rewrite. It earns its keep most when an operation has several distinct
failure modes.

**Tagged Results are not the only idiom**, and for simple cases plain Sequel is
often clearer:

- A `model.valid?` / `model.save` that returns the model with `model.errors`
  populated — fine for a single-model create/update where the route just re-renders
  the form. (The scaffold sets `Sequel::Model.raise_on_save_failure = false` so
  `save` returns `nil` instead of raising `Sequel::ValidationFailed` on invalid
  input.)
- Raising a domain exception and rescuing it at the boundary — fine when the failure
  really is exceptional, or when one `error` handler on `App` covers many routes.

Pick one approach per context and stay consistent. Whatever you pick: don't return a
bare boolean or `nil` where the caller needs to know *why* it failed, and never leak
a raw exception string out of the domain layer as the error (strings are a view concern).

### Default: `dry-monads`

Community default for typed Results — plain Ruby, no Rails needed.
([dry-monads](https://dry-rb.org/gems/dry-monads/), `gem "dry-monads", "~> 1.8"`)

```ruby
# app/services/notes/create.rb
module Notes
  class Create
    include Dry::Monads[:result]

    def self.call(...) = new.call(...)

    def call(account:, actor:, attrs:)
      return Failure([:unauthenticated]) unless actor
      return Failure([:forbidden]) unless NotePolicy.new(actor, Note).create?
      return Failure([:plan_limit_reached, { limit: 100, current: count_for(account) }]) if over_limit?(account)

      note = Note.new(attrs.merge(account_id: account.id))
      if note.save                                                   # false + note.errors on invalid
        MyApp::Audit.record("note.created", resource: note, actor: actor)  # side effects: see §5
        Success(note)
      else
        Failure([:validation, note.errors])
      end
    end
  end
end
```

> `Note` uses `plugin :validation_helpers`; `#validate` populates `note.errors`, and
> `note.errors` is a `Sequel::Model::Errors` object — structured data, not a string.

### Error taxonomy (use these tags verbatim)

| Result | Meaning | HTTP map |
|--------|---------|----------|
| `Success(value)` | ok | 200 / 201 |
| `Failure([:validation, errors])` | invalid input; `errors` is the model's Sequel errors object | 422 |
| `Failure([:not_found])` | record missing or out of scope | 404 |
| `Failure([:forbidden])` | authenticated but not allowed | 403 |
| `Failure([:unauthenticated])` | no/invalid identity | 401 |
| `Failure([:plan_limit_reached, meta])` | `meta` = `{ limit:, current: }` | 402 / 403 |
| `Failure([:conflict])` | uniqueness / duplicate / lost race | 409 |

Rules:

- ✅ `Failure([:validation, errors])` — tagged, the caller branches on `:validation`.
- ❌ `Failure(note.errors)` / `Failure("Title can't be blank")` — untagged; never
  return raw strings from a service. Strings are a view concern.
- The leading element is always a `Symbol`; the second (when present) is structured
  data, never a sentence.

### Handling the Result (pattern match)

dry-monads wraps the array as a tuple, so `case/in` deconstructs it directly.
Use `Failure[…]` (brackets) in patterns.
([pattern matching](https://hanakai.org/learn/dry/dry-monads/v1.8/pattern-matching))

**Route** (thin Sinatra block — parse params, invoke the service, render)

```ruby
# app.rb  (or app/routes/notes.rb registered on App)
post "/notes" do
  case Notes::Create.call(account: Current.account, actor: Current.user, attrs: note_params)
  in Success(note)
    redirect "/notes/#{note.id}"
  in Failure[:validation, errors]
    @errors = errors
    status 422
    erb :"notes/new"
  in Failure[:plan_limit_reached, meta]
    @meta = meta
    status 402
    erb :"notes/upgrade"
  in Failure[:forbidden]
    halt 403
  in Failure[:not_found]
    halt 404
  in Failure[code, *]
    logger.warn("unhandled result: #{code}")
    halt 422
  end
end

# there is no `params.require` — whitelist explicitly:
helpers do
  def note_params = params.slice("title", "body").transform_keys(&:to_sym)
end
```

> A `Failure[code, *]` catch-all arm is mandatory — an unmatched `case/in` raises
> `NoMatchingPatternError`. Every error tag must have a test exercising its arm.

### Simpler alternative: hand-rolled `Result`

If you do not want a dependency, a frozen value object works and **must mirror the
same tags** so it is swappable with dry-monads.

```ruby
module MyApp
  class Result
    attr_reader :value, :error
    def self.ok(value = nil)       = new(ok: true,  value: value)
    def self.err(*error)           = new(ok: false, error: error.freeze)
    def initialize(ok:, value: nil, error: nil) = (@ok, @value, @error = ok, value, error)
    def ok?  = @ok
    def err? = !@ok
    def deconstruct = ok? ? [value] : error   # enables `case/in`
  end
end

# MyApp::Result.err(:plan_limit_reached, { limit: 100, current: 100 })
# case result in [:plan_limit_reached, meta] then …
```

---

## 2. Audit Logging on Every Mutation

Every create / update / delete writes one audit row: **who, when, what changed,
from where**. No exceptions. Rows go in an `audit_logs` table — there is no
`audited`/`paper_trail` gem; the service writes the row itself.

### Audit row shape

| Column | Example | Source |
|--------|---------|--------|
| `actor_id` | current user id | `Current.user` |
| `account_id` | tenant / org id | `Current.account` |
| `action` | `"note.created"` | `resource.verb` convention |
| `resource_type` / `resource_id` | `"Note"` / `42` | the record |
| `changes` | `{"title" => ["old","new"]}` | JSON-encoded diff (`previous_changes`, `plugin :dirty`) |
| `request_id` | UUID | `Current.request_id` |
| `ip` | `"203.0.113.4"` | request |

Action naming is `resource.verb`: `note.created`, `note.updated`, `note.deleted`,
`member.invited`, `subscription.canceled`, `settings.updated`.

### Table + a small audit helper

```ruby
# db/migrate/003_create_audit_logs.rb
Sequel.migration do
  change do
    create_table(:audit_logs) do
      primary_key :id
      Integer     :actor_id
      Integer     :account_id
      String      :action,        null: false
      String      :resource_type, null: false
      Integer     :resource_id,   null: false
      String      :changes,       text: true          # JSON-encoded (SQLite has no JSON type)
      String      :request_id
      String      :ip
      DateTime    :created_at,     null: false
      index [:account_id, :created_at]
      index [:resource_type, :resource_id]
    end
  end
end
```

- **Service path (default):** a small helper the service calls directly, right after
  the mutation commits (§5). Reads actor/account/request_id/ip from the per-request
  context (§8), so the call site stays a one-liner.
- **Model-hook path:** a Sequel `after_create`/`after_update`/`after_destroy` hook (or
  a shared plugin) can write the row automatically — the analog of the gem's
  ActiveRecord callbacks. Trade-off: the hook fires *inside* the transaction and can
  only see request context if `Current` (§8) is populated. Prefer the explicit
  service call unless you need the guarantee that every path is covered.

```ruby
# app/services/audit.rb
require "json"

module MyApp
  class Audit
    def self.record(action, resource:, actor: Current.user, changes: nil)
      diff = changes || (resource.respond_to?(:previous_changes) ? resource.previous_changes : {})
      AuditLog.create(
        actor_id:      actor&.id,
        account_id:    Current.account&.id,
        action:        action,                        # "note.created"
        resource_type: resource.class.name,
        resource_id:   resource.id,
        changes:       JSON.generate(diff),           # TEXT column, JSON-encoded
        request_id:    Current.request_id,
        ip:            Current.ip,
        created_at:    Time.now
      )
    end
  end
end

# in the service, after save/commit:
MyApp::Audit.record("note.created", resource: note, actor: actor)
```

> `previous_changes` requires the model to load `plugin :dirty`. Audit rows are
> **append-only and never soft-deleted** (§3). Retention is a separate pruning job.

---

## 3. Soft Deletes on User-Facing Records

Never hard-delete a record a user expects to recover or that other records
reference. Use a `deleted_at` timestamp; filter it out by default; provide an
explicit `with_deleted` escape hatch for admin views and export. This is
hand-rolled — **no `discard` gem** — as a tiny Sequel plugin.

| Soft delete (`deleted_at`) | Hard delete (allowed) |
|----------------------------|-----------------------|
| `Note`, `Comment`, `Collection`, `Tag` | audit logs (append-only) |
| `Plan`, `Notification`, `WebhookEndpoint` | analytics/event rows (append-only) |
| `Account` (deactivate, don't destroy) | sessions / API tokens (revoke = gone) |

### Hand-rolled Sequel plugin

Adds a `deleted_at` filter to the default dataset plus `with_deleted` /
`only_deleted` escape hatches. (Dataset scopes and SQLite specifics: `.claude/database.md`.)

```ruby
# app/models/plugins/soft_delete.rb
module SoftDelete
  # runs once when the plugin is loaded onto a model
  def self.configure(model, column: :deleted_at)
    model.instance_variable_set(:@soft_delete_column, column)
    model.set_dataset(model.dataset.where(column => nil))   # default scope hides deleted rows
  end

  module ClassMethods
    attr_reader :soft_delete_column
    def with_deleted = dataset.unfiltered                                  # admin / export
    def only_deleted = dataset.unfiltered.exclude(soft_delete_column => nil)
  end

  module InstanceMethods
    def soft_delete
      now = Time.now
      this.update(model.soft_delete_column => now)   # dataset UPDATE: one statement, no hooks
      self[model.soft_delete_column] = now
      self
    end

    def restore
      model.with_deleted.where(model.primary_key => pk)
           .update(model.soft_delete_column => nil)
      self[model.soft_delete_column] = nil
      self
    end

    def deleted? = !self[model.soft_delete_column].nil?
  end
end
```

```ruby
class Note < Sequel::Model
  plugin :timestamps, update_on_create: true
  plugin :validation_helpers
  plugin :dirty
  plugin SoftDelete                    # deleted_at filtered out by default
end

# ✅ default — deleted rows excluded
Note.where(account_id: account.id).all
# ✅ admin / export — include deleted
Note.with_deleted.all
# delete = soft_delete + audit ("note.deleted")
note.soft_delete
MyApp::Audit.record("note.deleted", resource: note)
```

> Be deliberate with a default filter: a model whose dataset you restrict with
> `set_dataset(… where(deleted_at: nil))` filters deleted rows through its
> associations too. The common alternative is **no default filter** — define only a
> `kept` dataset method and call `.kept` in every finder (safer, but easy to forget).
> Pick one project-wide and document it.

Restoration sets `deleted_at` back to `nil` and records a `note.restored` audit entry.

---

## 4. Pagination on Every List

Every method returning a collection accepts `page` and `per_page`
(**default 25, max 100**) and returns a consistent paginated result — even if the
current UI shows everything. Backed by plain Sequel `.limit`/`.offset`.

```ruby
PER_PAGE_MAX = 100

def list_notes(account:, page: 1, per_page: 25)
  per   = [[per_page.to_i, 1].max, PER_PAGE_MAX].min
  pg    = [page.to_i, 1].max
  scope = Note.where(account_id: account.id).order(Sequel.desc(:created_at))
  total = scope.count
  rows  = scope.limit(per).offset((pg - 1) * per).all
  { results: rows, page: pg, per_page: per,
    total: total, total_pages: (total.to_f / per).ceil }
end
```

- ✅ every list method clamps `per_page` to 100 and returns the struct above.
- ❌ `Note.where(account_id: account.id).all` returned raw to the view — unbounded.

### Alternative: Sequel's `pagination` extension

Ships with Sequel; a paginated dataset carries its own page metadata.
([sequel pagination](https://sequel.jeremyevans.net/rdoc-plugins/files/lib/sequel/extensions/pagination_rb.html))

```ruby
DB.extension(:pagination)
page = Note.where(account_id: account.id).order(Sequel.desc(:created_at)).paginate(pg, per)
page.all                       # the rows for this page
page.current_page              # pg
page.page_count                # total_pages
page.pagination_record_count   # total
```

> Offset pagination scans skipped rows; for large tables index the `ORDER BY` column
> and consider keyset (`WHERE created_at < ?`) pagination. See `.claude/database.md`.

---

## 5. Side Effects After Commit

When a mutation has side effects — audit log, webhook dispatch, notification email,
cache invalidation — the service performs them directly, **after the write commits**.
Cheap, must-not-be-lost work (an audit row) runs inline; slow or external work
(webhooks, email, third-party sync) is handed to a **background job** so the request
isn't blocked and delivery is retryable.

```ruby
def call(...)
  note = nil
  DB.transaction do                                    # keep it short — SQLite has one writer
    note = Note.create(attrs.merge(account_id: account.id))
    # …any other writes that must be atomic with it…
  end

  # AFTER the transaction commits — side effects, called directly:
  MyApp::Audit.record("note.created", resource: note, actor:)              # inline: cheap, durable (§2)
  MyApp::WebhookJob.perform_async(note.account_id, "note.created", note.to_hash)  # enqueued (Sidekiq)
  MyApp::Cache.delete("account:#{note.account_id}:note_count")             # bust the cache key (if Redis cache)

  Success(note)
end
```

| Side effect | How |
|-------------|-----|
| Audit log | `MyApp::Audit.record(…)` inline after commit (§2) — cheap, must not be lost |
| Webhook dispatch | `MyApp::WebhookJob.perform_async(account_id, event, payload)` (Sidekiq) |
| Notification email | enqueue a Sidekiq job that sends via `Mail`/`Pony` — there is no ActionMailer |
| Cache invalidation | `MyApp::Cache.delete(…)` over Redis — only if a cache is configured (`app/cache.rb`) |

Run side effects **after** the transaction commits — after the `DB.transaction`
block as above, or from a `DB.after_commit { … }` callback registered inside the
transaction — so nothing reacts to a write that later rolls back. Never make a slow
external call **inside** the transaction: on SQLite that holds the single write lock
open for everyone (`.claude/database.md`).

> **Background jobs are not configured by default.** If no job system is present, the
> honest choices for slow/external work are (a) do it inline and accept the latency,
> or (b) add **Sidekiq** (needs Redis); a thread pool / `sucker_punch` covers light,
> non-durable async. Do not pretend a durable queue like Solid Queue exists.

> **When direct calls stop scaling.** If one mutation accretes many unrelated side
> effects, or the same effect is needed after several different mutations, a tiny
> in-process publish/subscribe object (mutation broadcasts, handlers react) is a
> reasonable refactor. `ActiveSupport::Notifications` works too but pulls in the
> `activesupport` gem — prefer a plain `Instrument`/observer. Reach for it when the
> duplication is real, not as the default.

---

## 6. Idempotency Keys on External Mutations

Every call that mutates state in a third party (charge, send, provision) carries an
idempotency key so a retry never double-applies. The key is **deterministic**,
derived from the operation — **never random** (a random key defeats the purpose on
retry). We also persist the key in an `idempotency_keys` table so our own side
detects a duplicate before calling out.

```
operation:tenant:resource:date_bucket
# e.g. "invoice.charge:acct_42:inv_9001:2026-06-01"
```

```ruby
# db/migrate/00X_create_idempotency_keys.rb
Sequel.migration do
  change do
    create_table(:idempotency_keys) do
      primary_key :id
      String   :key,        null: false
      String   :result,     text: true          # optional: cached response, JSON
      DateTime :created_at, null: false
      index :key, unique: true                   # the dedupe guard
    end
  end
end
```

```ruby
key = "invoice.charge:#{account.id}:#{invoice.id}:#{Date.today}"

# 1. our own guard — the UNIQUE index turns a retry into a no-op
begin
  DB[:idempotency_keys].insert(key: key, created_at: Time.now)
rescue Sequel::UniqueConstraintViolation
  return Failure([:conflict])                    # already applied
end

# 2. still forward the key to the third party (defense in depth)
Billing::Charge.call(amount:, currency: "usd", idempotency_key: key)   # Faraday client (app/clients/)
```

- ✅ deterministic — the same logical operation retried produces the same key.
- ❌ `idempotency_key: SecureRandom.uuid` — a retry generates a new key and charges twice.

Choose the `date_bucket` granularity to match how often the operation may *legitimately*
repeat (daily invoice → date; one-shot signup bonus → omit the bucket). The UNIQUE
index is cheap on SQLite, and the single-writer model serializes the insert naturally
(`.claude/database.md`).

---

## 7. Feature Flags

Gate plan-tier features and rollouts behind a **`flags` table**, enabled per actor,
account, or percentage — not by sprinkling `if account.plan == "pro"` through the
code. This is hand-rolled — **no Flipper gem** — as a small model plus a lookup helper.

```ruby
# db/migrate/00X_create_flags.rb
Sequel.migration do
  change do
    create_table(:flags) do
      primary_key :id
      String   :name,       null: false
      String   :scope_type, null: false, default: "global"   # global|actor|account|percentage
      Integer  :scope_id
      Integer  :percentage
      DateTime :created_at
      index [:name, :scope_type, :scope_id]
    end
  end
end
```

```ruby
# app/services/flags.rb
require "zlib"

module MyApp
  module Flags
    module_function

    def enabled?(name, actor: Current.user, account: Current.account)
      Flag.where(name: name.to_s).all.any? do |flag|
        case flag.scope_type
        when "global"     then true
        when "actor"      then actor && flag.scope_id == actor.id
        when "account"    then account && flag.scope_id == account.id
        when "percentage" then actor && bucket("#{name}:#{actor.id}") < flag.percentage
        end
      end
    end

    def enable_for_actor(name, actor)   = Flag.create(name: name.to_s, scope_type: "actor",   scope_id: actor.id)
    def enable_for_account(name, acct)  = Flag.create(name: name.to_s, scope_type: "account", scope_id: acct.id)
    def enable_percentage(name, pct)    = Flag.create(name: name.to_s, scope_type: "percentage", percentage: pct)

    # stable bucket so an actor doesn't flip in/out of a rollout between calls
    def bucket(seed) = Zlib.crc32(seed) % 100
  end
end
```

```ruby
MyApp::Flags.enabled?(:new_editor, actor: Current.user)   # per-actor / percentage
MyApp::Flags.enable_percentage(:new_editor, 25)           # gradual rollout
MyApp::Flags.enable_for_account(:beta_export, account)    # by account (group)
```

- ✅ `return Failure([:feature_not_enabled]) unless MyApp::Flags.enabled?(:export, account:)`
- ❌ hardcoded plan checks scattered across services and views.

---

## 8. Request Context (`Current`)

Per-request context (current user, account/tenant, request id, ip) lives in a
context object so it is available everywhere without threading it through every
method signature. **It must be reset per request** — Puma reuses threads, and there
is no Rails executor to clear it for you, so you reset it yourself in filters.

> **Scope ≠ authorization.** `Current` defines the *data boundary* (which tenant's
> rows you may even see). *Whether this actor may perform this action* is the policy
> object's job (`.claude/rbac.md`). Never use `Current` as an authorization check.

```ruby
# app/current.rb  (thread/fiber-local — no ActiveSupport::CurrentAttributes)
module Current
  KEY = :app_current

  module_function

  def reset! = Thread.current[KEY] = {}
  def store  = Thread.current[KEY] ||= {}

  def user       = store[:user]
  def account    = store[:account]
  def request_id = store[:request_id]
  def ip         = store[:ip]

  def set(**attrs) = store.merge!(attrs)
end
```

```ruby
# app.rb
class App < Sinatra::Base
  before do
    Current.reset!
    Current.set(
      request_id: request.env["HTTP_X_REQUEST_ID"] || SecureRandom.uuid,
      ip:         request.ip,
      user:       authenticate!                 # after auth resolution
    )
    Current.set(account: Current.user&.account) # tenant = data boundary
  end

  after { Current.reset! }                       # clear so nothing leaks onto a reused thread
end
```

Unlike Rails, nothing resets thread-locals automatically — the `after` filter (and a
`reset!` at the start) is what keeps state from leaking across requests. Repopulate
`Current` inside any background job's `perform` (§9); never rely on it surviving into
a worker. `request_id`/`trace_id` also feed structured logging — see `.claude/observability.md`.

---

## 9. Background Jobs Carry the Tenant / Scope Id

There are **no background jobs by default**; when you add them, use **Sidekiq**
(Redis). Every enqueued job includes the relevant **account/tenant id (and owner
id)** in its args — for fair scheduling, monitoring, and so the worker can
re-establish scope. A platform-wide job (cleanup, aggregation) is the only exception.

```ruby
# app/jobs/webhook_job.rb  (Sidekiq — only if a job system is configured)
module MyApp
  class WebhookJob
    include Sidekiq::Job

    def perform(account_id, event, payload)
      account = Account[account_id]      # re-establish the data boundary
      Current.reset!
      Current.set(account: account)      # thread is reused — repopulate, don't inherit
      logger.info(account_id: account_id, event: event)
      # …deliver…
    end
  end
end
MyApp::WebhookJob.perform_async(account.id, event, payload)
```

- ✅ `perform_async(account.id, note.id)`
- ❌ `perform_async(note)` with no tenant id, relying on ambient state that does not
  exist inside a worker.

Make jobs **idempotent** and add a **uniqueness** guard where a duplicate enqueue is
possible — `sidekiq-unique-jobs`, or reuse the `idempotency_keys` table (§6) keyed on
`account_id + resource_id`. Log the `account_id` at the start of `perform`. If Redis
(and thus Sidekiq) is not available, do the work inline or with a light thread pool —
do not pretend a durable queue exists.

---

## 10. Data Export (GDPR / DSAR)

Maintain one service that exports **all records scoped to a tenant, including
soft-deleted ones**. This is the foundation for data-subject-access-request
compliance and account migration.

```ruby
# app/services/export_account_data.rb
module MyApp
  class ExportAccountData
    def self.call(account)
      {
        account:    account.to_hash,
        notes:      Note.with_deleted.where(account_id: account.id).all.map(&:to_hash),
        comments:   Comment.with_deleted.where(account_id: account.id).all.map(&:to_hash),
        audit_logs: AuditLog.where(account_id: account.id).all.map(&:to_hash),
        # …one entry per tenant-scoped table…
      }
    end
  end
end
```

Rules:

- Include soft-deleted rows (`with_deleted`) with their `deleted_at` intact —
  omitting them breaks data portability.
- **Update this service every time you add a tenant-scoped table.** A missing table
  here is a silent compliance gap. A test should assert every tenant-scoped model
  appears in the export.

---

## New-Feature Checklist

When adding a feature, verify:

- [ ] Expected failures are surfaced as values, not control-flow exceptions — a tagged `Result` (the default), or `model.errors`; never a bare bool or raw string error
- [ ] Every `Failure[…]` tag (or error branch) has a route arm **and** a test
- [ ] New user-facing model loads the `SoftDelete` plugin (`deleted_at`); list queries filter it by default
- [ ] New model is scoped to the tenant (`account_id`)
- [ ] List methods accept `page` / `per_page`, clamp `per_page ≤ 100`, return the paginated struct
- [ ] Side effects (audit, webhooks, email, cache bust) run **after the write commits** — inline call for cheap/durable work, Sidekiq for slow/external work; nothing slow inside the transaction
- [ ] External mutations carry a **deterministic** idempotency key, guarded by the `idempotency_keys` table
- [ ] Plan-tier / rollout behavior is gated behind a `flags` entry (`MyApp::Flags`), not scattered plan checks
- [ ] Background jobs (if any) include `account_id` in args; idempotent + unique; repopulate `Current` in `perform`
- [ ] `MyApp::ExportAccountData` updated to include the new tenant-scoped table
- [ ] Authorization is enforced via a policy object (not via `Current`) — see `.claude/rbac.md`
- [ ] Every new behavior has a test (per CLAUDE.md)
