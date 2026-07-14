# CLAUDE.md — Generic Phoenix Project

Claude Code reads this every session. Follow all rules unless the user overrides for a
specific task. This is a **generic template** — replace `MyApp`/`MyAppWeb` with your real
OTP app and web module names, and adapt the example contexts/resources to your domain.

Detail patterns live in `.claude/`. Load the relevant file when working in that area.

### Stack Baseline

Phoenix 1.8 · LiveView 1.1 · Ecto 3.13+ · Tailwind v4 + daisyUI v5 · Bandit · OTP 27. Key
idioms: **Scopes** (phx.gen.auth default — context functions take a Scope struct first; data
boundary, not authorization), **LiveView streams** (default for large/unbounded collections;
bounded paginated lists may stay in assigns), **colocated hooks** + **keyed comprehensions**
(LiveView 1.1), **Req** (~> 0.5, default HTTP client on Finch), **magic-link auth**
(phx.gen.auth default) + `require_sudo_mode` for sensitive ops.

### Core (apply to any Phoenix app)

- `.claude/architecture-decisions.md` — audit logging, soft deletes, pagination, events, error tuples, feature flags
- `.claude/separation-of-concerns.md` — what belongs in a LiveView, controller, or context function
- `.claude/testing.md` — test-as-contract rule, factories, Mox mocks, `data-test` selectors, E2E
- `.claude/observability.md` — OpenTelemetry spans, metrics, structured logging
- `.claude/scalability.md` — write buffers, caching, connection management, PubSub, rate limiting
- `.claude/typescript-hooks.md` — LiveView JS hook conventions, file structure, events
- `.claude/deployment.md` — releases, CI/CD, secrets, migrations (DigitalOcean droplet + Docker Compose + Caddy, blue/green via GitHub Actions)
- `.claude/theming.md` — CSS-variable tokens (universal) + optional per-tenant theme loading
- `.claude/design-system.md` — **template**: document your visual design tokens and tone
- `.claude/frontend-map.md` — **template**: map your routes, LiveViews, components, hooks
- `.claude/a11y-audit.md` — WCAG 2.1 AA accessibility audit command

### Optional modules (include only if your app needs them)

- `.claude/multi-tenancy.md` — tenant scoping, query patterns, test isolation (shared-schema multi-tenant apps)
- `.claude/rbac.md` — roles, enforcement plugs, authorization (apps with role-based access)
- `.claude/external-service-integration.md` — pattern for wrapping any third-party API (media, email, SMS, …)
- `.claude/payment-integration.md` — billing/subscriptions/checkout (apps that charge money)
- `.claude/object-storage-integration.md` — S3-compatible file/blob storage (apps that store uploads)

---

## Project Overview

`MyApp` is a Phoenix 1.8 / LiveView application. Replace this section with your own
overview: what the app does, who uses it, and the high-level architecture.

### Architecture Summary

- **Interfaces:** typically an internal/admin UI and a public/end-user UI. Adapt to your app.
- **Background jobs:** Oban, with queues split by criticality.
- **External services:** wrapped behind client modules with behaviours (see
  `.claude/external-service-integration.md`). Never call a vendor SDK directly outside its client.
- **Deployment:** mix releases on your host of choice (see `.claude/deployment.md`).

### Context Modules

Business logic lives in context modules. LiveViews and controllers never call `Repo`
directly. Define the contexts your domain needs — common examples:

| Context         | Responsibility                                          |
|-----------------|---------------------------------------------------------|
| `Accounts`      | Users, authentication, memberships, invitations, RBAC   |
| `<Domain>`      | Your core domain resources (replace with real contexts) |
| `Billing`       | Subscriptions, plans, checkout (if you charge money)    |
| `Notifications` | Email/push notifications, delivery                      |
| `Admin`         | Platform-level / cross-tenant operations (if applicable)|

---

## Architecture Principles

Apply to every feature, context function, and schema. These are rules, not guidelines.
Detail patterns and code live in `.claude/architecture-decisions.md`,
`.claude/scalability.md`, and `.claude/observability.md`.

### 1. Protect Postgres from the Hot Path

Never write high-frequency data directly to Postgres. Any op firing more than once per
user per minute (analytics events, progress tracking, heartbeats) goes through a write
buffer (`MyApp.Buffer` behaviour) that batches and flushes periodically. The caller never
knows whether it was buffered or direct — same interface.

See `.claude/scalability.md` for the buffer pattern and which ops need it.

### 2. Separate Read and Write Paths

Structure context functions so reads can route to a DB replica and writes hit the primary.
Never mix reads and writes in one function unless transactional consistency requires it.
This enables future read-replica routing as a config change, not a rewrite.

### 3. Cache Frequently-Read, Infrequently-Written Data

Hot, rarely-changing data (config, metadata, lookups) goes through `MyApp.Cache`. The impl
is ETS/Cachex today and can swap to Redis later. Invalidate via the event system — a
mutation broadcasts an event that triggers cache invalidation across the cluster.

See `.claude/scalability.md` for what to cache and key conventions.

### 4. Minimize Persistent LiveView Connections

For high-traffic public pages, prefer an islands architecture: static server-rendered HTML
plus targeted LiveView components for interactive bits. Reserve full-page LiveView for the
admin dashboard and low-traffic authenticated pages.

Keep socket assigns lean. Load the minimum data for render. Never preload entire association
trees into assigns. Render large or unbounded collections with **LiveView streams**
(`stream/3,4`, `stream_insert`, `stream_delete`) rather than holding them in socket assigns;
bounded paginated lists may remain in assigns.

### 5. Broadcast Only What Multiple Processes Need

Use PubSub for content changes, cross-process events, and cache invalidation. Never PubSub
for per-user state (scroll position, heartbeats, per-session progress). Scope topics
narrowly — `events:{scope_id}`, not `events:global`.

See `.claude/scalability.md` for topic design rules.

### 6. Separate Background Jobs by Criticality

Oban queues by criticality: `critical` (payments), `default` (webhooks, notifications),
per-integration queues, and `bulk` (analytics, exports). High-volume work never shares a
queue with payments. Every Oban job includes the relevant scope id in its args.

### 7. Emit Events, Don't Inline Side Effects

Context functions broadcast events via `MyApp.Events`. Side effects (audit log, webhook
dispatch, analytics, notifications, cache invalidation) are handled by subscribers, not
inline. A new side effect is a new subscriber, not a change to existing code.

See `.claude/architecture-decisions.md` for the event broadcasting pattern.

### 8. Instrument Everything

Every context mutation gets an OpenTelemetry span. Every external API call gets a span with
service attrs. Every Oban worker restores trace context from the enqueuing request. Every
business-significant event emits a metric via `MyApp.Metrics`. Every log line uses
structured metadata with `trace_id`, `span_id`, and your scope/user ids. Use the
OpenTelemetry auto-instrumentation libraries (`OpentelemetryPhoenix` with `adapter: :bandit`
— `opentelemetry_bandit` is required on Bandit — `OpentelemetryEcto`, `OpentelemetryOban`)
for HTTP/DB/jobs; reserve manual spans for business logic and external calls not covered by
a library.

See `.claude/observability.md` for span naming, metric, and logging conventions.

### 9. Isolate Workloads (especially if multi-tenant)

DB queries indexed and paginated. Background jobs queue-separated. Cache keys namespaced.
Rate limiting per-actor. If multi-tenant: one tenant's bulk work must never starve another's
processing, and a misconfigured tenant must not slow others' page loads. See
`.claude/multi-tenancy.md`.

### 10. Design Interfaces for Tomorrow, Implement for Today

Use behaviours (`MyApp.Buffer`, `MyApp.Cache`, external client behaviours) so impls swap
without changing callers. Consistent error tuples so a future API layer maps cleanly to
HTTP. Pagination params on every list function even if the UI doesn't paginate yet. Feature
flags to gate by plan tier or rollout. Default to **Req** (on Finch) for new HTTP clients,
behind a behaviour-wrapped client module; HTTPoison/Tesla are acceptable for maintenance.

---

## Code Style Rules

## **NOTE: EVERY ADDITION THAT ADDS BEHAVIOR MUST BE ACCOMPANIED BY A TEST THAT VALIDATES SAID BEHAVIOR**

### Single Responsibility — One Function, One Job

Every function does one thing. If you write `and` in the `@doc`, the function needs a split.

### Pipe-First Data Transformation

Multi-step transformations use `|>`. Data flows top→bottom. Avoid intermediate vars when a
pipe expresses intent more clearly. Exception: a value used more than once, or where naming
improves readability.

### Doctests on Every Public Function

Every public function (`def`, not `defp`) must have an `@doc` block with at least one
doctest for the happy path. Exempt: functions that hit the DB or call external services —
use unit tests with mocks instead.

### Error Handling with Tagged Tuples

All fallible functions return specific, serializable tagged tuples:

```elixir
{:ok, resource}
{:error, :validation, changeset}
{:error, :not_found}
{:error, :forbidden}
{:error, :plan_limit_reached, %{limit: n, current: n}}
{:error, :external_service_error, details}
```

Never return a bare `{:error, changeset}` — always tag the error type. Never return string
error messages from context functions. See `.claude/architecture-decisions.md` for the full
error taxonomy.

### Private Functions Are Prefixed with Intent

```elixir
defp reject_expired_subscriptions(subs)  # ✅
defp filter_subs(subs)                   # ❌
```

### Contexts Are the Public API

All DB access goes through context modules. LiveViews and controllers never call `Repo`
directly. An `Admin` context may be the sole, clearly-documented exception for cross-scope
queries. Context functions take the current **Scope** as their first argument
(`list_posts(scope, opts)`, `get_post!(scope, id)`); the scope carries the user and, for
multi-tenant apps, the account/organization, and establishes the data boundary (not
authorization).

### Soft Deletes on User-Facing Content

Never hard-delete user-facing records. Use `deleted_at` timestamps. All list queries filter
soft-deleted by default. Provide explicit `_including_deleted` variants for admin views.
See `.claude/architecture-decisions.md`.

### Pagination on Every List Query

Every context function returning a list accepts `opts \\ []` with `page` + `per_page`, and
returns a pagination struct with `results`, `page`, `per_page`, `total`, `total_pages`. Max
`per_page` = 100.

### Audit Every Mutation

Every create, update, and delete is logged via the event system + an `AuditSubscriber`. The
audit log records who, when, what changed, and from which IP — including impersonation
context where applicable.

### Feature Files for Major User-Facing Features (Cucumberex)

Cucumberex (`mix cucumber`) is a default dependency. Every **major** user-facing feature —
a flow a user would name when describing the app (sign-up, checkout, publishing, inviting) —
gets a Gherkin `.feature` file under `features/` covering the happy path, significant
failure paths, and — where applicable — authorization and tenant isolation. Minor UI
details stay in LiveViewTest. See `.claude/testing.md` ("Acceptance Tests: Cucumberex")
for setup, step-definition patterns, and the sandbox hooks.

---

## Git Process: Trunk-Based Development & Atomic Commits

- Work off `main`. Keep branches short-lived. Rebase frequently. Never create merge commits.
  Maintain clean, linear history. Ship in small, safe increments.

**Before every commit:** run your verify task (format, credo, dialyzer) and `mix test`. No
commit if checks fail.

**Atomic commits** each do one thing, contain only related changes, leave the codebase in a
valid working state, and are independently reviewable. Avoid mixing refactors with behavior
changes, large multi-purpose commits, and "WIP"/"misc" commits.

**Commit message format:** `feat:`, `fix:`, `refactor:`, `test:` — be specific about what
changed.

Before opening or landing a PR: rebase onto latest `main`, clean up history, remove
WIP/debug commits. `main` is always releasable.

---

## Tests Are a Contract, Not an Obstacle

Existing tests describe intended behavior. They are specifications, not suggestions.

1. **Never modify an existing test to make it pass.** A previously-passing test that fails
   after your change means your change broke intended behavior. Fix the code, not the test.
   Only exception: a deliberate, explicitly-stated behavior change.
2. **Never weaken an assertion** to pass a failing test.
3. **Never delete a test to resolve a failure** — flag it for discussion.
4. **Never change existing function behavior to satisfy a new test** — add a new
   function/param instead.
5. **A new feature that breaks existing tests** carries the burden of proof — integrate
   without breaking existing behavior.
6. **If you believe a test is genuinely wrong**, flag it with a comment and ask before
   changing.
7. **Given a bug report**, write a failing test for the expected behavior, then fix.
8. **Find the root cause** — don't take the shortest route around an error message.

The test suite is a ratchet: it only moves forward. See `.claude/testing.md`.

---

## Accessibility — WCAG 2.1 AA Compliance

Every UI addition or modification must comply with WCAG 2.1 AA. A11y violations are bugs.

1. **Semantic HTML over ARIA** — use `<button>`, `<a>`, `<nav>`, `<main>`. Never `phx-click`
   on `<div>`/`<span>`.
2. **Keyboard navigable** — all interactive elements reachable via Tab; custom widgets
   support arrow keys, Escape, Enter/Space. No keyboard traps.
3. **Visible focus indicators** — never remove outlines without a replacement.
4. **ARIA labels on icon-only controls.** Active nav links use `aria-current="page"`.
5. **Color contrast** — text ≥ 4.5:1, large text ≥ 3:1, UI boundaries ≥ 3:1. Never convey
   info by color alone.
6. **Images** — every `<img>` has `alt`; decorative images use `alt=""`.
7. **Forms** — every input has a linked `<label>`; errors via `aria-describedby`; required
   fields marked.
8. **Motion** — auto-advancing content respects `prefers-reduced-motion` and has a visible
   pause control.
9. **Touch targets** — min 44×44 CSS px.
10. **Dynamic content** — flash messages and loading states use `aria-live`.

Run `/a11y-audit` (`.claude/a11y-audit.md`) to audit recent UI.

---

## What Not to Do

### Code
- No `Repo` calls outside context modules
- No multi-responsibility functions
- No public function without a doctest (exempt: DB + external service calls)
- No untested branch — every `case`/`cond`/`if` arm needs a test
- No `IO.inspect` left in committed code
- No string error messages from context functions — use tagged atoms
- No context function that doesn't take the current scope as its first argument (when scopes are configured)
- No `stream_update` — it doesn't exist; `stream_insert` handles both insert and update
- If multi-tenant: no cross-tenant data access outside documented `Admin` functions

### External Services
- No direct vendor (payment/media/storage) API calls outside their client modules
- No external API call without an idempotency key
- No external API call without an OpenTelemetry span
- No new HTTP client on raw HTTPoison/Tesla when Req fits — wrap Req behind a client module

### Data
- No hard deletes on user-facing content — use soft deletes
- No list function without pagination params
- No high-frequency writes direct to Postgres — use the buffer
- No unbounded preloads in socket assigns

### Infrastructure
- No `mix` commands in production — release commands only
- No secrets in `config/config.exs` or `config/prod.exs` — runtime only
- No deploys that skip tests
- No PubSub for per-user state
- No Oban job without its scope id in args

### Frontend
- No business logic in TypeScript/JS hooks — hooks are thin DOM/JS bridges
- No business logic in colocated or dedicated hooks — hooks stay thin
- No CSS classes as test selectors — use `data-test` attributes
- No hardcoded config that should come from the DB/runtime
- No `phx-click` on `<div>`/`<span>`
- No icon-only button without `aria-label`
- No interactive element without a visible focus indicator
- No auto-advancing content without `prefers-reduced-motion` support

### Logging

- No string interpolation in Logger calls — use structured metadata
- No Logger call without scope metadata where scope context exists
