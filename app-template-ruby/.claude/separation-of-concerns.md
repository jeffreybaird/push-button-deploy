# Separation of Concerns — Routes vs Service Objects vs Models

Load this file when writing or modifying any route block, service object, or
model. This is the rule that keeps the codebase ready for a JSON API, a
background worker, a CLI, or any future caller of the same logic.

> **Baseline:** Ruby 3.3+ · modular Sinatra (`class App < Sinatra::Base`) · Sequel + SQLite (WAL, Litestream). Thin routes → domain logic in service objects (the default for non-trivial work) or Sequel models. Request context via a `Current` module; authorization via plain-Ruby policy objects. dry-monads `Success`/`Failure` Results.

---

## The Rule

**Routes are thin adapters; the domain logic lives behind them.**

A route block's job is:

1. Parse and whitelist params (Sinatra has no strong params — build an explicit
   attribute hash; never pass raw `params` into a model).
2. Invoke the domain layer — a service object for anything non-trivial, or a
   model method / scoped dataset for a plain CRUD action.
3. Inspect the outcome (pattern-match a dry-monads Result, or check
   `record.errors`).
4. Set flash/status, then render (`erb`) or redirect.

Where the domain logic lives is a judgment call. A service object is the right home
when an operation spans multiple models, has side effects, or must be callable from
more than one entry point (web, API, job, CLI). For a plain create/update/destroy,
a model method, a dataset method, or the route coordinating a single `save`/`update`
is perfectly fine; don't wrap a one-line save in a ceremonial service. The line that
matters is the one below: business *rules* and orchestration don't live in the route.

A route must NEVER:

- Issue raw SQL (`DB[:notes]…`) or build ad-hoc dataset chains beyond a single
  named dataset method.
- Contain business rules (domain validation, authorization, state-machine logic).
- Run multi-step writes (two+ `save`/`update` calls that should be atomic — and on
  SQLite every write blocks the single writer, so an un-wrapped sequence is both a
  correctness *and* a contention bug; see `database.md`).
- Call external APIs directly (that's a Faraday client in `app/clients/`).
- Aggregate/transform data that another caller (API, worker, CLI) would also need.

**The test:** could a JSON endpoint on the same `App`, a Sidekiq worker, or a rake
task perform this same operation by calling the **same service object** with the
same arguments? If no — because the logic is trapped in the route — the separation
is broken.

This mirrors Sinatra's own framing: a route is a matcher plus a block, not a place
to compute ([Sinatra README](https://sinatrarb.com/intro.html)). The service-object
layer is the long-standing community pattern for "where the business logic goes"
([thoughtbot, "Skinny Controllers, Skinny Models"](https://thoughtbot.com/blog/skinny-controllers-skinny-models)).

---

## Layer responsibilities

| Layer | Owns | Never does |
|---|---|---|
| **Routes** (`class App < Sinatra::Base`) | Parse + whitelist params; invoke the domain layer (a service for non-trivial work, or a model method/dataset for trivial CRUD); inspect the outcome (Result or `record.errors`); set flash/status; render (`erb`) / redirect. | Business rules; raw SQL/datasets; multi-step orchestration; external API calls; authorization logic inline. |
| **Service objects** `app/services/notes/create.rb` (`Notes::Create`), a `self.call` returning a Result | Business rules; authorization checks (via policy objects); multi-step atomic ops (wrap in `DB.transaction`); external API calls; side effects after commit (audit, enqueued jobs, cache busting); returning a `Success`/`Failure`. | Rendering; touching `params`/`session`/`flash`; HTTP concerns. |
| **Models (Sequel::Model)** `app/models/note.rb` | Persistence; validations (`validation_helpers`); associations (`one_to_many`/`many_to_one`); dataset methods; record-level invariants. | Cross-aggregate orchestration; external calls; multi-record workflows (no fat models doing service work). |
| **Views / helpers** (ERB in `views/`) | Formatting only — currency, dates, thumbnail URLs, pluralization. | Business logic; queries; authorization. |

Any vanilla JS in `public/js/` is a presentation-layer bridge too — progressive
enhancement, thin, no business logic.

---

## Result type

The template's default is for service objects to return a tagged dry-monads Result
rather than a bare boolean or a raised exception for expected failures. Failures
carry a serializable tag so a future API maps cleanly to HTTP. (For simple
single-model actions, returning the record and reading `record.errors` — a Sequel
`Errors` hash — is a fine alternative; see `architecture-decisions.md` §1. The rule
that doesn't bend: expected failures are explicit outcomes, never a bare boolean or
a raw error string.)

```ruby
Success(note)
Failure([:validation, note.errors])          # Sequel::Model::Errors
Failure([:not_found])
Failure([:forbidden])
Failure([:plan_limit_reached, { limit: n, current: m }])
Failure([:external_service_error, details])
```

Never return a string error message from a service — use tagged symbols so callers
branch on `:plan_limit_reached`, not on prose.

---

## What belongs where — by example

### ✅ Route: parse, call one service, match Result <span title="stable">`[stable]`</span>

```ruby
class App < Sinatra::Base
  include Dry::Monads[:result]

  post "/notes" do
    attrs = params.slice("title", "body")   # whitelist — no strong params in Sinatra
    case Notes::Create.call(attrs:, actor: Current.user, account: Current.account)
    in Success(note)
      session[:notice] = "Note created."
      redirect "/notes/#{note.id}"
    in Failure([:plan_limit_reached, info])
      session[:alert] = "Note limit reached (#{info[:limit]})."
      redirect "/notes"
    in Failure([:validation, errors])
      @errors = errors
      erb :"notes/new"
    in Failure([:forbidden])
      halt 403
    end
  end
end
```

### ✅ Route: trivial read straight from a scoped dataset <span title="stable">`[stable]`</span>

```ruby
get "/notes" do
  @notes = Current.account.notes_dataset.kept.recent.paginate(page, per_page)  # one scoped read, fine
  erb :"notes/index"
end
```

A single named dataset method on the current-account association is acceptable in a
route. The moment it needs joins, conditionals, or aggregation, extract a **query
object** (`app/queries/notes/feed_query.rb`, `Notes::FeedQuery`).

---

## ✅/❌ Violation → fix

### Business rule in the route

```ruby
# ❌ "only if the account is under its note limit" is a domain rule
post "/notes" do
  account = Current.account
  if account.notes_dataset.kept.count < account.note_limit
    note = account.add_note(params.slice("title", "body"))
    session[:notice] = "Note created."
    redirect "/notes/#{note.id}"
  else
    session[:alert] = "Note limit reached."
    redirect "/notes"
  end
end
```

```ruby
# ✅ rule lives in the service; route only matches the Result
post "/notes" do
  case Notes::Create.call(attrs: params.slice("title", "body"),
                          actor: Current.user, account: Current.account)
  in Success(note)                        then redirect "/notes/#{note.id}"
  in Failure([:plan_limit_reached, _])    then (session[:alert] = "Note limit reached."; redirect "/notes")
  end
end
```

The service returns `Failure([:plan_limit_reached, …])` when the account is at its
limit.

### Raw query in the route

```ruby
# ❌ ad-hoc dataset building in the block
get "/notes" do
  @notes = DB[:notes]
             .where(account_id: Current.account.id, deleted_at: nil)
             .order(Sequel.desc(:created_at))
             .all
  erb :"notes/index"
end
```

```ruby
# ✅ a dataset method (or query object) owns the query shape
class Note < Sequel::Model
  dataset_module do
    def kept   = where(deleted_at: nil)
    def recent = order(Sequel.desc(:created_at))
  end
end

get "/notes" do
  @notes = Current.account.notes_dataset.kept.recent.paginate(page, per_page)
  erb :"notes/index"
end
```

### Multiple saves in one block

```ruby
# ❌ three writes that must be atomic, scattered in the route — and on SQLite
#    each one grabs the single writer, so a mid-sequence failure half-commits
post "/notes" do
  note = Current.account.add_note(params.slice("title", "body"))
  Current.account.default_notebook.add_note(note)
  note.update(pinned: true)
  redirect "/notes/#{note.id}"
end
```

```ruby
# ✅ one service wraps them in a transaction and returns a Result
module Notes
  class Create
    def self.call(...) = new(...).call

    def initialize(attrs:, actor:, account:)
      @attrs, @actor, @account = attrs, actor, account
    end

    def call
      return Failure([:forbidden]) unless NotePolicy.new(@actor, Note).create?
      return Failure([:plan_limit_reached, limit_info]) if over_limit?

      note = DB.transaction do
        n = @account.add_note(@attrs)          # raises Sequel::ValidationFailed if invalid
        @account.default_notebook.add_note(n)
        n.update(pinned: true)
        n
      end
      # after commit — side effects run against the committed record
      MyApp::Audit.record("note.created", resource: note, actor: @actor)
      Success(note)
    rescue Sequel::ValidationFailed => e
      Failure([:validation, e.model.errors])   # transaction already rolled back
    end

    private

    def over_limit?  = @account.notes_dataset.kept.count >= @account.note_limit
    def limit_info   = { limit: @account.note_limit, current: @account.notes_dataset.kept.count }
  end
end
```

Run side effects **after** the transaction commits — as above (the record is
returned from the `DB.transaction` block, then side effects run against it), or via a
Sequel `after_commit` hook or an enqueued job — so nothing reacts to a write that
later rolls back. Keep the `DB.transaction` body short: SQLite has one writer, so a
long transaction stalls every other write (see `database.md`).

---

## Service-object creation workflow

When an audit or a new feature needs something no service supports, build the
service **first** — never put logic in the route "temporarily."

1. **Define** the class: `<Context>::<Verb>` (e.g. `Notes::Create`) in
   `app/services/notes/create.rb`, with a class-level `self.call` delegating to an
   instance.
2. **Implement**: authorization (a policy object), business rules, `DB.transaction`
   for multi-step writes, external calls (Faraday client), side effects after commit
   (audit, jobs), returning a `Success`/`Failure`.
3. **Spec it**: cover the happy path and every `Failure` branch
   (`:plan_limit_reached`, `:forbidden`, `:validation`, …). Each example runs in a
   rolled-back Sequel transaction. Every behavior gets a test.
4. **THEN call it** from the route and match the Result.

Temporary route logic becomes permanent debt the moment you add a JSON API or a
worker.

---

## Request-scoped data via `Current`

There is no `ActiveSupport::CurrentAttributes`. Use a small hand-rolled `Current`
module backed by thread/fiber-local storage for request context — `Current.account`,
`Current.user`, `Current.request_id`. Populate it in a `before` filter and clear it
in an `after` filter so nothing leaks between requests on a reused thread.

```ruby
module Current
  class << self
    %i[account user request_id].each do |name|
      define_method(name)        { store[name] }
      define_method("#{name}=")  { |v| store[name] = v }
    end

    def reset! = Thread.current[:current] = {}
    private def store = Thread.current[:current] ||= {}
  end
end

class App < Sinatra::Base
  before do
    Current.reset!
    Current.request_id = request.env["HTTP_X_REQUEST_ID"]
    Current.user       = User[session[:user_id]] if session[:user_id]
    Current.account    = Current.user&.account
  end

  after { Current.reset! }
end
```

- **Routes** populate `Current` from the session/token. They never build tenant
  filters themselves.
- **Services and models** read scope through the current-account association
  (`Current.account.notes_dataset`) — the scope filter lives here.
- **For testability**, prefer passing the actor/account as explicit args to a
  service (`Create.call(actor:, account:, …)`) and reading `Current` only at the
  route boundary, so specs can call the service without a global. A service may read
  `Current` directly when an explicit arg would be pure ceremony — but keep it
  consistent within a context.

```ruby
# ❌ route hand-rolls the tenant filter
@notes = Note.where(account_id: Current.account.id)

# ✅ scope rides the association; the model/service owns the boundary
@notes = Current.account.notes_dataset.kept
```

`Current` is the **data** boundary, not authorization. Scoping answers *which rows is
this actor allowed to see*; a policy object answers *is this actor allowed to do
this*. Both belong in the service layer, not the route — the service applies the
scope and checks the policy, returning `Failure([:forbidden])` when denied. See
`multi-tenancy.md` for the scoping patterns.

---

## Patterns for when it gets complex

- **Query objects** (`app/queries/`, bare namespace e.g. `Notes::FeedQuery`): when a
  read needs joins, conditional filters, or aggregation beyond a single dataset
  method. Routes and services call the query object; neither builds the dataset
  chain inline.
- **Form objects**: when a single submission spans multiple models or needs
  validations that don't belong on any one record. The form object validates and
  hands clean attrs to a service.

---

## Route audit checklist

Before committing changes to any route block:

- [ ] No raw SQL / ad-hoc dataset chains (single named dataset method on a scoped
      association is OK).
- [ ] No business-rule conditionals (`if account.notes_dataset.count < …`).
- [ ] No multi-step saves/updates (extract to a service + `DB.transaction`).
- [ ] No direct external API calls (use a Faraday client).
- [ ] No hand-rolled tenant filter (`where(account_id: …)`) — scope rides the
      association.
- [ ] No inline authorization logic — a policy object, applied in the service.
- [ ] Every service called exists and is spec'd (happy path + every `Failure`).
- [ ] Every Result branch is handled (no unmatched `case`/`in` — an unmatched
      pattern raises `NoMatchingPatternError`).

---

## Related docs

- `architecture-decisions.md` — Result/error tags, audit logging, soft deletes, pagination, side effects after commit
- `database.md` — Sequel models/datasets, SQLite/WAL single-writer constraints, migrations, Litestream
- `external-service-integration.md` — Faraday client wrapper pattern for third-party APIs
- `testing.md` — RSpec + Rack::Test + Capybara patterns, FactoryBot, rolled-back transactions, request/feature specs
- `multi-tenancy.md` — tenant scoping and dataset patterns (if applicable)
