# Database — Sequel + SQLite + Litestream

The data layer for this stack. Read this before writing anything that touches the schema, does
bulk or high-frequency writes, or reasons about concurrency. SQLite is not "Postgres but
smaller" — its concurrency model is genuinely different, and most of the rules below follow
from one fact: **one writer at a time**.

Related: `.claude/architecture-decisions.md` (soft deletes, pagination, audit), `.claude/scalability.md`
(buffering, caching, no replicas), `.claude/deployment.md` (how the DB file + Litestream run in prod).

---

## The connection

One global `DB`, created once in `config/database.rb`:

```ruby
require "sequel"

db_path = ENV.fetch("DATABASE_PATH") do
  env = ENV.fetch("RACK_ENV", "development")
  File.expand_path("../db/#{env}.sqlite3", __dir__)
end

DB = Sequel.connect(adapter: "sqlite", database: db_path)

DB.run "PRAGMA journal_mode=WAL"   # readers don't block the single writer
DB.run "PRAGMA busy_timeout=5000"  # wait up to 5s for the write lock instead of erroring
DB.run "PRAGMA foreign_keys=ON"    # SQLite defaults FKs OFF — turn them on

Sequel::Model.plugin :timestamps, update_on_create: true
Sequel::Model.plugin :validation_helpers
```

- **`DATABASE_PATH`** is the single source of truth for where the file lives. In production the
  deploy sets it to an on-volume path (e.g. `/data/my_app.sqlite3`); locally it defaults to a
  per-environment file under `db/`. Never hardcode a path elsewhere.
- **WAL mode is mandatory here**, for two reasons: readers run concurrently with the one
  writer (the only real read concurrency SQLite offers), and it is the journal mode Litestream
  replicates. Don't switch it off.
- **`busy_timeout`** turns an instant `SQLITE_BUSY` into a bounded wait. It is a smoother, not
  a fix — the fix is fewer, shorter write transactions (see below).
- **`foreign_keys=ON`** must be set on every connection; SQLite ignores FK constraints unless
  you do.

There is exactly one `DB`. Do not open ad-hoc second connections to the same file — you'll
multiply the write contention you're trying to avoid.

---

## The single-writer rule (the thing that bites)

A write transaction takes a lock on the **entire database file**. While it's held, every other
write waits (up to `busy_timeout`, then raises `Sequel::DatabaseError` wrapping `SQLITE_BUSY`).
Reads proceed (WAL), but writes are serialized globally — not per-table, not per-row.

Consequences, all of which are rules elsewhere in these docs:

- **Keep write transactions short.** Do all the slow work (HTTP calls, rendering, computation)
  *outside* `DB.transaction`. Open the transaction, write, commit, done.

  ```ruby
  # ❌ external call holds the write lock for the length of a network round-trip
  DB.transaction do
    order = Order.create(...)
    PaymentClient.new.charge!(order)   # NO — network I/O inside the write lock
  end

  # ✅ do I/O first, keep the transaction to the writes
  charge = PaymentClient.new.charge!(params)
  DB.transaction do
    Order.create(..., charge_id: charge.id)
  end
  ```

- **Never write high-frequency data row-by-row.** Counters, analytics, progress, heartbeats:
  buffer them (in memory or Redis) and flush in one batched insert. See `.claude/scalability.md`.

  ```ruby
  # ✅ one write transaction for N rows, not N transactions
  DB[:events].multi_insert(buffered_rows)
  ```

- **Enqueue jobs after commit, never inside the transaction** — an enqueue that runs inside a
  long transaction extends the lock and can enqueue work for a row that then rolls back.

- **Retry `SQLITE_BUSY` at the edges only.** With short transactions + `busy_timeout` you
  rarely see it. If a specific bulk path can contend, wrap that path in a small bounded retry
  — don't sprinkle retries everywhere.

Puma's thread count is kept low (`config/puma.rb`) for the same reason: more threads mostly
means more writers queuing for the one lock, not more throughput.

---

## Models

Sequel models are thin: persistence, associations, validations, invariants. Business
orchestration is a service object (`.claude/separation-of-concerns.md`).

```ruby
class Note < Sequel::Model
  many_to_one :account
  one_to_many :comments

  dataset_module do
    def recent = order(Sequel.desc(:created_at))
    def for_account(account) = where(account_id: account.id)
  end

  def validate
    super
    validates_presence :body
    validates_max_length 10_000, :body, allow_nil: false
  end
end
```

- **Associations** are `many_to_one` / `one_to_many` / `many_to_many` — not `belongs_to`/`has_many`.
- **Validations** use the `validation_helpers` plugin inside `def validate`.
- **Query building** lives in `dataset_module` methods (the equivalent of scopes), so callers
  chain `Note.for_account(acct).recent.limit(25)` instead of scattering `where` across the app.
- **`save` semantics:** by default Sequel *raises* `Sequel::ValidationFailed` on invalid save.
  Service objects usually prefer to branch on a value — check `record.valid?` first and return a
  `Failure`, or set `raise_on_save_failure false` on the model and check the return of `save`.
  Be consistent within a context.
- **Avoid N+1:** use `eager` for the display path (`Note.eager(:comments)`), `eager_graph` when
  you must filter across the association.

---

## Migrations

Timestamped/`NNN`-numbered files in `db/migrate/`, run by Sequel's migrator via Rake:

```ruby
# db/migrate/002_add_account_to_notes.rb
Sequel.migration do
  change do
    alter_table(:notes) do
      add_foreign_key :account_id, :accounts, null: false, index: true
    end
  end
end
```

```ruby
# Rakefile task
namespace :db do
  task :migrate do
    require_relative "config/database"
    Sequel::Migrator.run(DB, "db/migrate")
  end
end
```

Rules:

- **`change` for reversible migrations** (most: create/alter table, add index). Use `up`/`down`
  when a change isn't auto-reversible (raw SQL, data backfills).
- **Additive and backward-compatible.** The deploy runs migrations as a **gate before traffic
  switches** and does a blue/green swap, so for a moment the *old* code runs against the *new*
  schema. A migration must never break the currently-running release: add columns/tables, don't
  rename or drop in the same deploy that stops using them. Split destructive changes across two
  deploys (stop using it → deploy → drop it → deploy).
- **Index every foreign key and every column you filter or sort on.** SQLite will happily table-scan;
  confirm with `EXPLAIN QUERY PLAN` (you want `SEARCH ... USING INDEX`, not `SCAN`).
- **SQLite `ALTER TABLE` is limited** (no drop/rename column on older SQLite; the bundled
  `sqlite3` gem is recent enough for most, but complex table rewrites may need the
  create-copy-drop-rename dance — Sequel does this for you where it can).
- **Never edit a migration that has run in production.** Add a new one.

Migrations run in production via `docker compose run --rm migrate bundle exec rake db:migrate`
(the deploy's migration gate — see `.claude/deployment.md`), and in tests via `Sequel::Migrator`
in `spec/spec_helper.rb` against a fresh test DB.

---

## Soft deletes

Hand-rolled (there is no `discard` gem): a `deleted_at` column plus a dataset that hides
soft-deleted rows by default.

```ruby
# migration
alter_table(:notes) { add_column :deleted_at, DateTime }

# model
class Note < Sequel::Model
  dataset_module do
    def kept = where(deleted_at: nil)
    def only_deleted = exclude(deleted_at: nil)
  end

  def soft_delete = update(deleted_at: Time.now)
end
```

Default your read paths to `Note.kept`; expose `with_deleted`/`only_deleted` explicitly for
admin views. Full treatment (plus making `kept` the model's default dataset) is in
`.claude/architecture-decisions.md`.

---

## Transactions & concurrency helpers

- `DB.transaction { ... }` — one unit of work. Nest safely with `savepoint: true`.
- `DB.after_commit { ... }` — run side effects (cache bust, enqueue) only once the write lands.
  This is the correct place to enqueue Sidekiq work.
- `SELECT ... FOR UPDATE` does not exist in SQLite. The single write lock is your mutex; design
  around short transactions rather than row locks.

---

## Litestream (durability & disaster recovery)

The SQLite file lives on the droplet's disk. **Litestream** continuously streams the WAL to
object storage (DO Spaces) so the data survives the droplet, and restores it on a fresh
droplet before the app boots. It is configured in `deploy/litestream.yml` and runs as a
sidecar + a one-shot restore in the compose stack — see `.claude/deployment.md`.

What this means for you as an app author:

- **Litestream is DR, not a replica.** You cannot query it, and it is not a read scale-out.
  Reads still come from the one local file.
- **It replicates WAL frames**, which is why WAL mode is mandatory and why you should not fight
  the journal settings.
- **There is a small replication lag window.** If the droplet dies between WAL pushes, the last
  fraction of a second of writes can be lost. For most small apps that's an acceptable trade for
  a $0 database; if it isn't, use the Postgres/Phoenix backend instead.
- **Don't bypass the app to mutate the file** (e.g. `sqlite3` CLI writes on the droplet) — those
  still replicate, but you lose the app's validations, audit rows, and cache invalidation.

---

## Local development & tests

- **Dev:** `bundle exec rake db:migrate` creates `db/development.sqlite3`; the file is
  gitignored. Delete it to start clean.
- **Tests:** `spec/spec_helper.rb` points `DATABASE_PATH` at a disposable `db/test.sqlite3`,
  recreates it from migrations before the suite, and wraps each example in a transaction rolled
  back afterward (`DB.transaction(rollback: :always)`). This is fast and isolated *because* a
  single in-process connection is shared — see the caveat in `.claude/testing.md` for browser
  (`:js`) specs, which run in a separate process and can't share the rollback.

---

## Checklist

- [ ] New table/column has an index for every FK and every filtered/sorted column
- [ ] Migration is additive & safe for the currently-running release (blue/green + gate)
- [ ] No external I/O or slow work inside a `DB.transaction`
- [ ] High-frequency writes are buffered and batch-inserted, not row-by-row
- [ ] Side effects (cache bust, enqueue) run in `after_commit`, not mid-transaction
- [ ] Read paths default to the soft-delete-aware dataset (`kept`)
- [ ] `EXPLAIN QUERY PLAN` shows `USING INDEX` for hot queries
- [ ] Foreign keys are enforced (`PRAGMA foreign_keys=ON`) and validated in specs
