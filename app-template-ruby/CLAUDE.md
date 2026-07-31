# CLAUDE.md — Generic Ruby Project (Sinatra + Sequel + SQLite)

Claude Code reads this every session. Follow all rules unless the user overrides for a
specific task. This is a **generic template** — replace `MyApp` / `my_app` with your real
module and app names, and adapt the example domain (the `Note` resource, its service objects,
its routes) to yours.

Detail patterns live in `.claude/`. Load the relevant file when working in that area.

### Stack Baseline

Ruby 3.3+ · **modular Sinatra** (`class App < Sinatra::Base`, served by **Puma** via
`config.ru`) · **Sequel** ORM · **SQLite** (WAL mode, replicated to object storage by
Litestream). Key conventions: domain logic in **service objects returning Result types**
(dry-monads), not routes; request context via a hand-rolled **`Current`** module
(`Current.user` / `Current.account`) — the data boundary, *not* authorization; **plain-Ruby
policy objects** for authorization; **Faraday** for HTTP; views are **ERB** (no
Hotwire/Turbo/Stimulus); **RSpec + Rack::Test + Capybara** for tests. Background work, when
needed, is **Sidekiq** (Redis) — there is none by default.

This is deliberately a lean stack: Sinatra gives you routing and little else, so most
structure here is a convention we impose, not a framework feature. When something isn't
built in, the honest answer is "plain Ruby + an explicit `require`", not a Rails-ism.

### Core (apply to any Ruby web app)

- `.claude/architecture-decisions.md` — Result/error objects, audit logging, soft deletes, pagination, side effects, feature flags, idempotency
- `.claude/separation-of-concerns.md` — what belongs in a route, a service object, a model, a view
- `.claude/database.md` — **read this before any write-heavy or schema work**: Sequel, SQLite realities (single writer, WAL, `busy_timeout`), migrations, Litestream
- `.claude/testing.md` — test-as-contract rule, FactoryBot, WebMock/VCR, `data-testid` selectors, request + feature specs
- `.claude/observability.md` — OpenTelemetry, structured logging, a hand-rolled `Instrument` event bus
- `.claude/scalability.md` — write buffers, caching, jobs by criticality, SSE, rate limiting — all under the SQLite single-writer constraint
- `.claude/deployment.md` — the push-button-deploy pipeline: Docker + Puma, Caddy TLS, blue/green swap, the `rake db:migrate` gate, secrets/ENV
- `.claude/theming.md` — CSS-variable tokens + optional per-tenant theming
- `.claude/design-system.md` — **template**: document your visual design tokens and tone
- `.claude/frontend-map.md` — **template**: map your routes, services, ERB views, JS modules
- `.claude/a11y-audit.md` — WCAG 2.1 AA accessibility audit command

### Optional modules (include only if your app needs them)

- `.claude/multi-tenancy.md` — `account_id` row-level scoping, `Current.account`, test isolation
- `.claude/rbac.md` — authentication (session + bcrypt), roles on memberships, policy objects
- `.claude/external-service-integration.md` — wrapping any third-party API behind a Faraday client class
- `.claude/payment-integration.md` — Stripe billing/subscriptions/checkout + webhooks
- `.claude/object-storage-integration.md` — S3-compatible blob storage (presigned uploads; store keys, not blobs)

---

## Project Overview

`MyApp` is a Sinatra web application. Replace this section with your own overview: what the
app does, who uses it, and the high-level architecture.

### Architecture Summary

- **The app:** one `class App < Sinatra::Base` (`app.rb`). Routes are thin — they parse
  params, invoke the domain layer, and render ERB. Larger apps split routes into
  `app/routes/*.rb` files registered on `App`.
- **Domain logic:** service objects (`app/services/<domain>/`) that return Result types;
  Sequel models (`app/models/`) hold persistence and invariants.
- **Data:** a single global `DB = Sequel.connect(...)` (`config/database.rb`) against one
  SQLite file. One writer at a time — see `.claude/database.md`.
- **Background jobs:** none by default. Reach for Sidekiq (Redis) when you need durable
  async; light in-process work can use a thread pool, with the single-writer caveat.
- **External services:** wrapped behind Faraday client classes (`app/clients/`). Never call
  a vendor SDK directly outside its client. See `.claude/external-service-integration.md`.
- **Deployment:** Docker + Puma on a DigitalOcean droplet via the push-button-deploy
  pipeline (Caddy TLS, blue/green, Litestream). See `.claude/deployment.md`.

### Domain Modules

Business logic lives in service objects and models. Routes never embed business rules or raw
queries. Common examples:

| Area            | Responsibility                                            |
|-----------------|-----------------------------------------------------------|
| `Accounts`      | Users, authentication, memberships, invitations, RBAC     |
| `Notes`         | The example domain resource (replace with your real ones) |
| `Billing`       | Subscriptions, plans, checkout (if you charge money)      |
| `Notifications` | Email/push notifications, delivery                        |

---

## Architecture Principles

Apply to every feature, service object, and model. These are rules, not guidelines. Detail
patterns and code live in `.claude/architecture-decisions.md`, `.claude/database.md`,
`.claude/scalability.md`, and `.claude/observability.md`.

### 1. Respect the Single Writer

SQLite serializes writes: exactly one write transaction runs at a time, and it locks the
whole database file. Never write high-frequency data row-by-row on the hot path (analytics,
counters, progress, heartbeats) — you will hit `SQLITE_BUSY`. Buffer (in memory or Redis) and
flush in one batched `multi_insert`, or use atomic Redis counters. Keep every write
transaction short. `busy_timeout` is set so contenders wait rather than error, but the fix is
fewer, shorter writes — not a longer timeout. See `.claude/database.md`.

### 2. Reads Scale with Caching, Not Replicas

There is one database file; you cannot add a read replica. WAL mode lets readers run
concurrently with the single writer, and that plus indexing plus caching (a small Redis
wrapper) is how reads scale here. Structure code so a read path never opens a write
transaction it doesn't need. This is the deliberate tradeoff of the SQLite backend — accept
it or choose the Postgres/Phoenix stack instead.

### 3. Cache Frequently-Read, Infrequently-Written Data

Hot, rarely-changing data (config, metadata, lookups) goes through a cache wrapper
(`app/cache.rb` over Redis) if you have one; otherwise memoize per request. Invalidate on
write — the service that mutates the data (or a Sequel `after_commit` hook on the model)
busts the cache key once the change commits. There is no `Rails.cache`; be explicit.

### 4. Keep the Client Lean

Server-rendered ERB is the default and the path to reach for first. Add small vanilla-JS
modules (`public/js/`) only for genuine interactivity; there is no Turbo/Stimulus here. Keep
payloads lean, avoid N+1 (Sequel `eager`), and don't ship entire association trees to a view.
Reserve Server-Sent Events for genuinely realtime features.

### 5. Domain Logic in Service Objects, Not Routes

A route parses params, calls one service, and renders. Business rules, multi-step
orchestration, raw SQL, and external API calls live in `app/services/` (or model methods for
simple cases). If a route body is more than a few lines, extract a service. See
`.claude/separation-of-concerns.md`.

### 6. Separate Background Jobs by Criticality

If you add Sidekiq, split queues by criticality: `critical` (payments), `default` (webhooks,
notifications), `bulk` (analytics, exports). High-volume work never shares a queue with
payments. Every job carries its account/scope id in arguments and re-establishes `Current`.
Enqueue **after** the DB transaction commits (never inside it) — see `.claude/scalability.md`.

### 7. Instrument Everything

Use OpenTelemetry auto-instrumentation for HTTP/DB/Faraday; add manual spans for multi-step
business logic and external calls. Emit an event on every business-significant action through
the `Instrument` bus. Every log line is structured JSON with `request_id`, `trace_id`, and
account/user ids. See `.claude/observability.md`.

### 8. Design Interfaces for Tomorrow, Implement for Today

Wrap external services behind client classes so implementations swap without touching
callers. Consistent Result types so a future JSON API maps cleanly to HTTP. Pagination params
on every list method even if the UI doesn't paginate yet. A simple `flags` table to gate by
plan tier or rollout. See `.claude/architecture-decisions.md`.

---

## Code Style Rules

## **NOTE: EVERY ADDITION THAT ADDS BEHAVIOR MUST BE ACCOMPANIED BY A TEST THAT VALIDATES SAID BEHAVIOR**

### Single Responsibility — One Object, One Job

A service object does one thing and exposes a single `call`. If you write "and" in its
description, split it.

### Keep Domain Logic Out of Routes

Skinny routes: parse params, invoke the domain layer, render the outcome. No business rules,
raw queries, multi-step orchestration, or external API calls in a route block. *Where* that
domain logic lives is a judgment call: a Sequel model method or dataset for simple CRUD, and a
service object when an operation spans multiple models, has real side effects, or must be
callable from more than one entry point (web, API, job, CLI). Don't manufacture a one-line
service for a trivial save. See `.claude/separation-of-concerns.md`.

### Make Expected Failures Explicit, Not Exceptions

Expected, recoverable outcomes (not found, invalid input, over a plan limit) should be values
the caller can branch on, not exceptions raised for control flow. This template's default is a
tagged Result (`dry-monads`):

```ruby
Success(resource)
Failure([:validation, errors])
Failure([:not_found])
Failure([:forbidden])
Failure([:unauthenticated])
Failure([:plan_limit_reached, { limit:, current: }])
Failure([:conflict])
```

Tagged Results pay off most when an operation has several distinct failure modes or a future
API must map them to HTTP. For simpler cases, idiomatic alternatives are fine — a Sequel
model where `save` returns falsey (with `raise_on_save_failure = false`) and exposes
`model.errors`, or raising and rescuing a domain exception at the boundary. Whatever you pick,
be consistent within a context, never return a bare boolean/`nil` where the caller needs to
know *why* it failed, and never leak a raw exception string out of the domain layer as the
error. See `.claude/architecture-decisions.md` for the full taxonomy.

### Request Context via `Current`, Scoped in Services

Service objects read `Current.account` / `Current.user` (or accept them as arguments for
testability). Routes never build the tenant filter — scoping lives in services and Sequel
datasets. `Current` is a thread-local module reset in a `before` filter and cleared in an
`after` filter (Puma reuses threads — you must clear it). `Current` is the **data boundary**,
not authorization.

### Soft Deletes on User-Facing Content

Never hard-delete user-facing records. Use a `deleted_at` timestamp column and a Sequel
dataset that excludes soft-deleted rows by default; provide explicit `with_deleted` variants
for admin views. This is hand-rolled on the model — there is no `discard` gem. See
`.claude/architecture-decisions.md`.

### Pagination on Every List

Every method returning a list accepts `page` + `per_page` (default 25, max 100, clamped) and
returns a paginated result (Sequel `limit`/`offset`, or the `pagination` extension). See
`.claude/architecture-decisions.md`.

### Audit Every Mutation

Every create, update, and delete is recorded — the service writes a row to an `audit_logs`
table after the mutation commits: who, when, what changed, from which IP, including
impersonation context where applicable. This is a plain Sequel table, not a gem.

### Authorization Is Separate from Scoping and Authentication

Authentication = who you are (session + bcrypt). Tenant scoping (`Current.account`) = which
rows you may touch. Authorization (a policy object) = which actions you may perform. A valid
scope still needs an authorization check. Enforce in routes **and** re-check in services. See
`.claude/rbac.md`.

---

## Tests Are a Contract, Not an Obstacle

Existing tests describe intended behavior. They are specifications, not suggestions.

1. **Never modify an existing test to make it pass.** A previously-passing test that fails
   after your change means your change broke intended behavior. Fix the code, not the test.
   Only exception: a deliberate, explicitly-stated behavior change.
2. **Never weaken an assertion** to pass a failing test.
3. **Never delete a test to resolve a failure** — flag it for discussion.
4. **Never change existing behavior to satisfy a new test** — add a new method/argument instead.
5. **A new feature that breaks existing tests** carries the burden of proof.
6. **If you believe a test is genuinely wrong**, flag it and ask before changing.
7. **Given a bug report**, write a failing spec for the expected behavior, then fix.
8. **Find the root cause** — don't take the shortest route around an error message.

The suite is a ratchet: it only moves forward. See `.claude/testing.md`.

---

## Accessibility — WCAG 2.1 AA Compliance

Every UI addition or modification must comply with WCAG 2.1 AA. A11y violations are bugs.

1. **Semantic HTML over ARIA** — `<button>`, `<a>`, `<nav>`, `<main>`. Navigation is an
   `<a href>`; a state change is a `<form method="post">` with a real `<button>`; never a
   click handler on a `<div>`/`<span>`.
2. **Keyboard navigable** — everything reachable via Tab; custom widgets support arrow keys,
   Escape, Enter/Space. No keyboard traps.
3. **Visible focus indicators** — never remove outlines without a replacement.
4. **ARIA labels on icon-only controls.** Active nav links use `aria-current="page"`.
5. **Color contrast** — text ≥ 4.5:1, large text ≥ 3:1, UI boundaries ≥ 3:1. Never convey
   info by color alone.
6. **Images** — every `<img>` has `alt`; decorative images use `alt=""`.
7. **Forms** — every input has a linked `<label for>`; errors via `aria-describedby`;
   required fields marked.
8. **Motion** — respects `prefers-reduced-motion`; auto-advancing content has a pause control.
9. **Touch targets** — min 44×44 CSS px.
10. **Dynamic content** — SSE/JS updates, flashes, and loading states use `aria-live`.

Run `/a11y-audit` (`.claude/a11y-audit.md`) to audit recent UI.

---

## Git Process: Trunk-Based Development & Atomic Commits

- Work off `main`. Keep branches short-lived. Rebase frequently. Never create merge commits.
  Ship in small, safe increments.

**Before every commit:** run your verify task (`rubocop`, `bundle exec rspec`, `bundler-audit`).
No commit if checks fail.

**Atomic commits** each do one thing, contain only related changes, leave the codebase in a
valid working state, and are independently reviewable. Avoid mixing refactors with behavior
changes and "WIP"/"misc" commits.

**Commit message format:** `feat:`, `fix:`, `refactor:`, `test:` — be specific.

`main` is always releasable — every push to `main` deploys (see `.claude/deployment.md`).

---

## What Not to Do

### Code
- No business logic or raw queries in route blocks — use service objects and Sequel datasets
- No domain method returning a bare boolean/`nil` where the caller must know *why* it failed — surface the reason (a tagged Result, `model.errors`, or a domain exception)
- No `raise` for ordinary control flow — reserve exceptions for the exceptional
- No service or query that ignores `Current.account` when scopes are configured (multi-tenant)
- No untested branch — every conditional arm needs a spec
- No `binding.pry` / `puts` / `p` debugging left in committed code
- No fat models doing cross-aggregate orchestration or external calls

### Data
- No hard deletes on user-facing content — use soft deletes (`deleted_at`)
- No list method without pagination params
- No high-frequency row-by-row writes to SQLite — buffer and batch (single writer!)
- No long-held write transaction — keep them short to avoid `SQLITE_BUSY`
- No N+1 queries in views — preload with Sequel `eager`
- No `Sequel.migration` that isn't run by the `rake db:migrate` deploy gate

### External Services
- No direct vendor (Stripe/AWS/etc.) calls outside their Faraday client class
- No external mutation without an idempotency key
- No webhook processed without verifying its signature over the raw request body first
- No external API call without an OpenTelemetry span

### Infrastructure
- No infrastructure change outside `infra/` — the Terraform roots in this repo own the droplet, DNS and state bucket (see `infra/README.md`); clicking it in the DO console makes the next apply fight you
- No secrets in source — use `ENV.fetch` (dev/test via `dotenv`, prod via the deploy `.env`)
- No deploys that skip tests
- No background job without its account/scope id in arguments
- No job enqueued inside a DB transaction — enqueue after commit

### Frontend
- No business logic in JS modules — they are thin DOM bridges
- No CSS classes as test selectors — use `data-testid`
- No hardcoded config that should come from the DB/runtime
- No click handler on a `<div>`/`<span>` — use `<button>`/`<a>`/`<form>`
- No icon-only control without an `aria-label`
- No interactive element without a visible focus indicator

### Logging
- No string interpolation of context into log lines — use structured fields
- No log line without `request_id`/`trace_id` and scope metadata where context exists
