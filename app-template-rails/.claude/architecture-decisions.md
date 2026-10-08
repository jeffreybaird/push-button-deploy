# Architecture decisions

The fresh Rails scaffold demonstrates these conventions with Notes. Add domain
features only when required; optional guides do not install infrastructure.

## Domain operations and results

Group operations by domain under `app/services/notes/`. `Notes::Create.call(attrs:)`
returns `Success(note)` or `Failure([:validation, errors])`; archive returns
`Success(note)` or `Failure([:not_found])`. Expected failures are explicit values,
not booleans or exception-driven branching. Handle every tag at the HTTP boundary
and test its successful and failed behavior. Unexpected database or programming
errors propagate; do not disguise them as validation failures.

Models own validation, associations and named query scopes. Controllers whitelist
parameters, call operations and translate results into redirects, status codes
and locals. Views render locals; they do not query or authorize records.

## Durable mutations and observations

Create and archive write an `AuditLog` in the same Active Record transaction as
the note. Its `event`, `record_id` and `created_at` contain no note content.
An audit failure must roll back the mutation. Add actor identifiers only when
real authentication exists; never invent an actor or log sensitive field values.

Publish `notes.created` and `notes.archived` with only `note_id` through
`ActiveSupport::Notifications` in `ActiveRecord.after_all_transactions_commit`.
This waits for the outer transaction and emits nothing on rollback. Notifications
are synchronous, in-process and non-durable. A subscriber exception occurs after
commit and must not be returned as a validation failure implying rollback.

For future critical external effects, persist an outbox entry atomically and
process it with idempotent delivery. An after-commit callback alone has a
commit-to-delivery crash window and cannot guarantee delivery.

## Recoverability and bounded reads

`Note.kept` excludes `archived_at` rows explicitly. Archive preserves content;
missing or previously archived IDs return `Failure([:not_found])`. Do not add a
global `default_scope`. Recovery and retention/erasure operations must be
intentional and separately authorized when authentication is introduced.

`Notes::List.call(page: 1, per_page: 25)` returns `items`, `page`, `per_page`,
and `total`. Clamp page to at least one and page size to 1–100. Use stable
`created_at, id` ordering; never load unbounded collections to paginate in Ruby.

When introducing tenants, pass a resolved scope explicitly to operations;
scoping determines visible records and policies determine permitted actions.
See `multi-tenancy.md` and `rbac.md`. Feature flags, exports, jobs and caches
are optional extensions, not generated services.
