# Multi-Tenancy — Row-Level Scoping by `account_id`

> **Optional module.** Include only if your app is multi-tenant. A single-tenant
> app can skip this file entirely.

Load this file when working on any feature that touches tenant-scoped data — a new
model, a query, a service, a list route.

> **Baseline:** Ruby 3.3+ · modular Sinatra (`class App < Sinatra::Base`) · Sequel
> + SQLite (WAL, Litestream). Shared-schema row-level scoping by `account_id` is
> the default; `Current.account` carries the tenant, set in a `before` filter.
> Scoping rides Sequel datasets derived from `Current.account`
> (`Current.account.notes_dataset`) — never a global implicit scope. Scope = data
> boundary, not authorization (policy objects — see `rbac.md`). Errors are
> dry-monads `Success`/`Failure([:tag])`.

Maturity tags: <span title="stable">`[stable]`</span> ship it · <span title="mature">`[mature]`</span> proven, heavier · <span title="emerging">`[emerging]`</span> verify before relying.

---

## Core Principle

A multi-tenant app shares one database and one set of tables across all tenants.
Isolation is enforced at the **application layer**, not the database layer. The
tenant model in this guide is `Account` — your app may call it `Organization`,
`Workspace`, or `Tenant`; the rules are identical.

**The SQLite single-file reality.** This stack is one SQLite file on a droplet
volume (WAL journal, Litestream-replicated — see `database.md`). Every tenant's
rows live side by side in that **one file**; there are no Postgres schemas and no
per-tenant partitions to hide behind. Isolation is therefore **purely row-level,
enforced in Ruby** — a query that forgets its `account_id` filter reads every
tenant's data. That is why the scoping discipline below and the mandatory
isolation specs (§9) are not optional hygiene; they are the entire boundary.

### Isolation strategy — pick by isolation need

Shared-schema with an `account_id` foreign key is the **default**, threaded through
`Current.account`. Reserve the heavier strategy for a strong-isolation/compliance
requirement — it costs real operational complexity (a migration run per file, a
Litestream stream per file, connection juggling, separate backups).

| Strategy | When to use | Trade-off | Maturity |
|---|---|---|---|
| **Row-level (`account_id` FK)** — *default* | Almost every app; thread via `Current.account` | App-layer isolation; a missed dataset filter leaks data — all tenants share one SQLite file | Stable, no dependency |
| **Database-file-per-tenant** (a separate `.db` file per account) | Regulatory / contractual hard isolation, a few large tenants | Migrations + Litestream + connection pools fan out per file; cross-tenant reads need an explicit switch; highest ops cost | Plain Sequel; heavy ops |

> Most apps should never leave row #1. If you think you need a file per tenant,
> confirm it is a compliance/contractual requirement, not a hypothetical.

---

## 1. Schema Rules

### Every tenant-scoped table has `account_id`

No exceptions. If data belongs to a tenant, it carries an `account_id` foreign key
**with an index**. The only tables without it are `accounts` itself and
system-level tables (background-job tables, global feature flags).

```ruby
# db/migrate/004_create_notes.rb
Sequel.migration do
  change do
    create_table(:notes) do
      primary_key :id
      # FK + cascade. SQLite enforces foreign keys only with PRAGMA foreign_keys = ON,
      # which Sequel's sqlite adapter sets per connection by default (see database.md).
      foreign_key :account_id, :accounts, null: false, on_delete: :cascade
      String   :title, null: false
      String   :slug,  null: false
      DateTime :created_at
      DateTime :updated_at

      index :account_id
      index [:account_id, :slug], unique: true   # uniqueness scoped to the account (below)
    end
  end
end
```

Use `on_delete: :cascade` on the `account_id` FK so deleting an `Account` cascades
cleanly. Never leave orphaned tenant rows — orphaned tenant data is a
data-integrity bug. (If your app soft-deletes accounts instead, cascade is moot;
you scope soft-deleted accounts out of queries — see soft deletes in
`architecture-decisions.md`.)

### Composite uniqueness is scoped to the account

Any uniqueness constraint (slug, plan name, external ref) must be scoped to the
account. A globally unique slug is wrong — two accounts must be free to use the
same one. Enforce it in **both** the model and the database.

```ruby
# app/models/note.rb
class Note < Sequel::Model
  plugin :validation_helpers
  many_to_one :account

  def validate
    super
    validates_presence [:account_id, :title, :slug]
    validates_unique   [:account_id, :slug]   # composite — friendly error
  end
end
# the DB index [:account_id, :slug] unique (§ migration above) is the real guarantee

# ❌ WRONG — globally unique slug blocks two accounts from sharing one
#   validates_unique :slug
```

The model validation gives a friendly error; the DB unique index is the guarantee
under a race — `validates_unique` alone has a check-then-insert gap, so the index
does the real work ([Sequel validation_helpers](https://sequel.jeremyevans.net/rdoc-plugins/classes/Sequel/Plugins/ValidationHelpers.html)).

---

## 2. Request-scoped tenant via `Current.account`

The resolved tenant is carried for the duration of the request in the hand-rolled
`Current` module (thread/fiber-local), set **once** after resolution and **reset**
at request end. Models and services read `Current.account`; they never receive it
from — or trust it from — the raw request.

### The hand-rolled `Current` module <span title="stable">`[stable]`</span>

There is no `ActiveSupport::CurrentAttributes` here. The `Current` module is
defined in full in `separation-of-concerns.md`; it is backed by
`Thread.current` storage and exposes `Current.account`, `Current.user`,
`Current.request_id`. Nothing resets it for you — you wire the `before`/`after`
filters yourself:

```ruby
# app.rb
class App < Sinatra::Base
  before do
    Current.reset!                              # clear any leaked state on a reused thread
    Current.user    = User[session[:user_id]] if session[:user_id]
    Current.account = resolve_account           # §7 — the single resolution point
  end

  after { Current.reset! }
end
```

The `after` filter is load-bearing: Puma reuses threads, so a missed reset would
leak one request's tenant into the next. `Current` is the DATA boundary — it
carries identity and tenant, it does not authorize (that's `rbac.md`).

---

## 3. Scope every query

Models and services apply the `account_id` filter; **routes never build the tenant
filter** (see `separation-of-concerns.md`). Prefer the reverse-association dataset
off `Current.account`; fall back to an explicit `where(account_id:
Current.account.id)` where there is no convenient association.

```ruby
# ✅ CORRECT — scoped through the account's reverse association; cannot reach another tenant
Current.account.notes_dataset.with_pk!(id)                       # raises Sequel::NoMatchingRow if out of scope
Current.account.notes_dataset.where(published: true).order(Sequel.desc(:created_at))

# ✅ ALSO CORRECT — an explicit named dataset filter ("a default dataset filter", opt-in)
class Note < Sequel::Model
  dataset_module do
    def for_account(account) = where(account_id: account.id)
  end
end
Note.for_account(Current.account).all

# ✅ ALSO CORRECT — explicit filter inline when neither fits
Note.where(account_id: Current.account.id).with_pk!(id)

# ❌ WRONG — global lookup, leaks across all tenants
Note.with_pk!(id)      # or Note[id]
Note.all
```

`Current.account.notes_dataset` and `for_account` are **opt-in, explicit** filters
— the caller names the scope every time. That is the whole difference from an
implicit global default scope (§6): nothing is applied behind your back, so
nothing is silently stripped behind your back either.

### Never trust a client-supplied `account_id`

The tenant comes from the resolved `Current.account`, **never** from params, a
hidden field, or a JSON body. Treating a request value as the tenant is a
straight cross-tenant read/write hole.

```ruby
# ❌ NEVER — an attacker sets any account_id they like
Note.where(account_id: params[:account_id]).all
Current.account.add_note(attrs)                 # if attrs still carries account_id from the client

# ✅ account_id is stamped from the tenant; strip any client-supplied one first
attrs = params.slice("title", "slug")           # whitelist — no account_id passes through
Current.account.add_note(attrs)                 # add_note (from one_to_many :notes) stamps account_id
```

`add_note` is the Sequel association writer generated by `one_to_many :notes` on
`Account` (§4); it sets `account_id` to the current tenant, so the client can
never choose it.

In a service, scope first, then act, returning tagged Results for expected misses:

```ruby
# ✅ service: scope first, then act (see separation-of-concerns.md)
def call
  note = @account.notes_dataset.first(id: @id)  # #first returns nil, never raises
  return Failure([:not_found]) unless note
  # ...
  Success(note)
end
```

`with_pk!` (raises `Sequel::NoMatchingRow`) suits a route that halts 404;
`first(id:)` (returns `nil`) suits a service returning `Failure([:not_found])`.
Both respect the dataset's `account_id` filter — that is what makes them safe.

---

## 4. No automatic scope — associations are the mechanism (and the discipline)

Sequel has **no `acts_as_tenant`** and no strict-mode "raise on any unscoped
query" safety net. There is nothing to install; the tenant boundary is the
`account_id` association plus the discipline of always riding it. Set the
associations up once and route every read/write through them:

```ruby
# app/models/account.rb
class Account < Sequel::Model
  one_to_many :notes          # → account.notes_dataset, account.add_note(...)
  one_to_many :memberships
end

# app/models/note.rb
class Note < Sequel::Model
  many_to_one :account        # → note.account, note.account_id
end
```

Because nothing raises automatically on a forgotten filter, the safety net is
**code review plus the mandatory isolation specs in §9** — every read path gets a
test proving account A cannot see account B's rows. Treat that spec as the
strict-mode equivalent you have to write by hand.

> Tempted to bake a global tenant filter into the model's dataset so you can stop
> typing `Current.account`? That is the Rails `default_scope` idea, and Sequel can
> express it — but it carries the same traps. See §6 for why the template refuses
> it.

---

## 5. Database-file-per-tenant — strong-isolation alternative (heavier ops)

When a contract or regulator demands physical isolation, give each tenant its own
SQLite **file** (and its own Litestream stream) instead of sharing rows in one
file. This is plain Sequel — a per-tenant `Sequel.connect` resolved from a
registry — but the ops cost is real, so reach for it only under a hard
requirement. <span title="mature">`[mature]`</span>

```ruby
# a per-tenant connection, resolved from the account — NOT the default path
def db_for(account)
  # one file per tenant; each is Litestream-replicated to its own object-store prefix
  Sequel.connect("sqlite://storage/tenants/#{account.id}.db")
end

# block-scoped use — every model call inside sees only this tenant's file
db_for(account).transaction do
  # ... queries run against the tenant's own database ...
end
```

What this buys and what it costs:

- **Buys:** a forgotten filter can no longer leak across tenants — the other
  tenants' rows are not in the file at all.
- **Costs:** every migration must run against **every** file (a migration
  fan-out); Litestream needs a stream per file; you juggle a connection pool per
  file; and cross-tenant reads (analytics, admin) require an explicit switch or a
  fan-out loop. The SQLite single-writer rule (`database.md`) now applies
  **per file** — which is a scaling *benefit* here, since writes to different
  tenants no longer contend.

| Approach | Isolation | Ops cost | Use when |
|---|---|---|---|
| Row-level `account_id` (default) | App-layer, one shared file | Lowest | Almost always |
| Database-file-per-tenant | Physical, one file each | Highest (migrate × files, stream × files) | Regulatory hard isolation, few large tenants |

---

## 6. Why not a global implicit tenant scope

You *can* make Sequel filter every query implicitly — override the model's dataset
or wrap it in a `Model.dataset` that reads `Current.account`. This is the Rails
`default_scope` pattern, and it leaks in exactly the same surprising ways, so the
template does **not** use it:

- It stamps `account_id` onto `new`/`create` implicitly — attributes you may not
  have meant to set, applied invisibly.
- It evaluates `Current.account` at query time. In a Sidekiq job or a rake task
  with **no tenant set**, it scopes to `account_id IS NULL` and silently returns
  nothing (or, if mis-built, everything).
- `Note.unfiltered` (Sequel's equivalent of `unscoped`) strips it entirely — and
  it is easy to forget that one call just removed all tenant isolation.
- It bleeds into eager loads and association datasets in ways that are hard to
  audit.

```ruby
# ❌ AVOID — an implicit global tenant filter baked into the model's dataset
class Note < Sequel::Model
  # a dataset that silently reads Current.account for every query: leaks into
  # create, evaluates against an unset Current in jobs, and Note.unfiltered nukes it
  def self.dataset = super.where(account_id: Current.account&.id)
end

# ✅ PREFER — explicit, opt-in scoping (§3): named every time, stripped never
Current.account.notes_dataset          # reverse association
Note.for_account(Current.account)      # named dataset method
```

Rule: **prefer explicit `Current.account.notes_dataset` (or a named
`for_account` dataset method) over an implicit global tenant scope.** Typing the
scope is the feature, not the friction — a scope you can see is a scope you can
review.

---

## 7. Tenant resolution

Resolve the tenant from the request, set `Current.account`, in **one** place — the
`before` filter (§2). Individual routes never re-resolve it.

### Session / membership (default here) <span title="stable">`[stable]`</span>

This stack authenticates with a Rack session cookie (see `rbac.md`), so the common
resolution is simply the signed-in user's account:

```ruby
helpers do
  def resolve_account
    Current.user&.account          # the account carried by the authenticated user
  end
end
```

Public routes (login, signup, marketing) have no tenant — that is fine; a `nil`
`Current.account` is expected there. Guard **tenant** routes with a filter that
halts when scope is required:

```ruby
def require_account!
  halt 404 unless Current.account
end
# before "/notes*" is a tenant area:  before("/notes*") { require_account! }
```

### Subdomain / custom domain (option) <span title="mature">`[mature]`</span>

For subdomain multitenancy behind Caddy, resolve from `request.host`. Sinatra/Rack
has **no `request.subdomain` helper** — parse the label yourself:

```ruby
def resolve_account
  subdomain = request.host.split(".").first        # no request.subdomain in Sinatra
  Account.first(custom_domain: request.host) ||
    Account.first(subdomain: subdomain) ||
    Current.user&.account                          # session fallback
end
```

`Account.first(...)` returns `nil` (not a raise) on no match, so the `||` chain
falls through cleanly. The `before` filter is the single resolution point; keep
resolution out of the routes.

---

## 8. No unscoped queries except a documented Admin layer

The only code allowed to query across tenants is an explicit, clearly-namespaced
system/admin layer. Sinatra has no controller namespaces, so the honest equivalent
is a **separate `Sinatra::Base` app mounted under `/admin`** (the pattern in
`rbac.md` §5):

```ruby
# config.ru
map("/admin") { run Admin::App }

# app/admin/app.rb
class Admin::App < Sinatra::Base
  before { halt 403 unless Current.user&.super_admin? }   # the ONLY place scope is bypassed

  get "/notes" do
    @notes = Note.dataset        # documented cross-tenant read — every account's rows
    erb :"admin/notes/index"
  end
end
```

Any cross-tenant query **outside** this layer is a bug. Scoping is a **data
boundary, not authorization** — a valid scope says *which rows are visible*, never
*which actions are permitted*. Pair scoping with a **policy object** for the verb
(see `rbac.md`):

```ruby
# ❌ WRONG — scope treated as the authorization check
note = Current.account.notes_dataset.with_pk!(id)   # visible, yes — but may THIS user delete it?
note.destroy

# ✅ CORRECT — scope for visibility, a policy for the action
note = Current.account.notes_dataset.with_pk!(id)              # tenant scope
return Failure([:forbidden]) unless
  NotePolicy.new(Current.user, note).destroy?                  # authorization (rbac.md)
note.destroy
```

| Concern | Question | Mechanism |
|---|---|---|
| **Scoping** | Which records are visible to this request? | `Current.account.notes_dataset` / `account_id` filter |
| **Authorization** | Which actions may this user perform on them? | Policy object (`NotePolicy`) — see `rbac.md` |

---

## 9. Test Isolation

The single-file reality (Core Principle) means the test database is one SQLite
file with every fixture account's rows interleaved — exactly like production. So a
scoping bug is invisible unless a test explicitly reaches for the wrong tenant's
row. These specs are the boundary; write them.

Specs run under RSpec + FactoryBot, each example wrapped in a Sequel transaction
rolled back at the end (`DB.transaction(rollback: :always, auto_savepoint: true)`
— see `testing.md`).

### Every test builds its own account

Never rely on a shared/global account. Each example creates its own.

```ruby
let(:account_a) { create(:account) }
let(:account_b) { create(:account) }
```

### Mandatory cross-tenant read spec

For **every** read path, assert that account A cannot reach account B's rows. This
is the most important category of test in a multi-tenant system — not optional.
A scoped dataset raises `Sequel::NoMatchingRow` on an out-of-scope primary key:

```ruby
# spec/models/note_isolation_spec.rb
it "cannot read another account's note" do
  account_a = create(:account)
  account_b = create(:account)
  other     = create(:note, account: account_b)

  Current.account = account_a
  expect {
    Current.account.notes_dataset.with_pk!(other.id)   # scoped finder
  }.to raise_error(Sequel::NoMatchingRow)
ensure
  Current.reset!
end

it "lists only the current account's notes" do
  account_a = create(:account)
  account_b = create(:account)
  mine   = create(:note, account: account_a)
  _other = create(:note, account: account_b)

  Current.account = account_a
  expect(Notes::List.call.value!).to contain_exactly(mine)   # Current.account.notes_dataset under the hood
ensure
  Current.reset!
end
```

### Mandatory cross-tenant write spec

Prove account A cannot **mutate** account B's row. A service scoped through the
account dataset rejects the out-of-scope id with `Failure([:not_found])` — scope,
not authorization, does the rejecting — and the victim row is untouched:

```ruby
it "cannot update another account's note" do
  account_a = create(:account)
  account_b = create(:account)
  victim = create(:note, account: account_b, title: "original")

  Current.account = account_a
  result = Notes::Update.call(account: Current.account,
                              note_id: victim.id,
                              attrs:   { title: "hijacked" })

  expect(result).to eq(Failure([:not_found]))         # out of scope → not found (never :forbidden)
  expect(Note.with_pk!(victim.id).title).to eq("original")   # unchanged
ensure
  Current.reset!
end
```

Reset `Current` in an `ensure` so a set tenant never leaks into the next example
(the transaction rolls back the *data*, not the thread-local). Per the project
rule: every read path gets its isolation spec, and every `Failure` branch in a
scoped service gets a test.

---

## Related docs

- `separation-of-concerns.md` — the `Current` module definition; route vs service boundary; where scope is applied
- `rbac.md` — authorization (policy objects), the scope-vs-authorization split, the mounted `Admin::App` cross-tenant exception
- `database.md` — Sequel models/datasets, migrations, the single-writer SQLite/WAL constraint, foreign-key PRAGMA, Litestream
- `architecture-decisions.md` — Result/error tags (`:not_found`, `:forbidden`), soft deletes, audit logging
- `testing.md` — RSpec + Rack::Test + Capybara, FactoryBot, rolled-back transactions, `Sequel::NoMatchingRow` isolation assertions
