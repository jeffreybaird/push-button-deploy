# MyApp — Rails application guidance

Read the shared agent workflow first. Preserve role ownership, accepted tests,
current security audits and safe precommit correction requirements.

## Generated application

Rails, Active Record, SQLite and Puma serve a small Notes example. Domain
operations return explicit dry-monads Results; controllers stay thin, ERB uses
locals, and recoverable content is archived rather than destroyed. Durable audit
rows commit with mutations; IDs-only notifications run after the outer commit.
Lists are indexed, stably ordered and bounded. Keep this single-database service
small; optional guides do not install auth, tenants, jobs or external services.

## Required checks

Run `bin/check`: test database preparation, RuboCop (Rails/RSpec), RSpec, strict
Cucumber, SimpleCov with **100% line and 100% branch coverage** across all app/lib
Ruby files, then bundler-audit with current advisory data. No stale coverage,
threshold bypasses, excluded application code or suppressed cops. Before commit,
safely autocorrect owned Ruby files, then rerun checks. Read `testing.md` for
suite isolation and the explicit legacy gate for adopted applications.

## Working conventions

Expected errors are `Failure([:tag, details])`; unexpected errors raise. Test
successful behavior and every expected rejection. Whitelist request input,
use Rails forms/CSRF, escape user output and keep authorization separate from
data scoping. Use semantic design tokens, accessible controls, stable data-testid
hooks and meaningful empty/error states. Keep UI logic on the server and any
future JavaScript small. Never log secrets, personal data or note contents.

## Supporting guides

- `.claude/architecture-decisions.md` — Architecture decisions
- `.claude/separation-of-concerns.md` — Separation of concerns
- `.claude/database.md` — Database
- `.claude/testing.md` — Testing and quality gates
- `.claude/frontend-map.md` — Frontend map
- `.claude/design-system.md` — Design system
- `.claude/a11y-audit.md` — Accessibility review
- `.claude/theming.md` — Optional theming
- `.claude/rbac.md` — Optional authentication and authorization
- `.claude/multi-tenancy.md` — Optional multi-tenancy
- `.claude/observability.md` — Observability
- `.claude/scalability.md` — Scalability
- `.claude/external-service-integration.md` — Optional external services
- `.claude/payment-integration.md` — Optional payments
- `.claude/object-storage-integration.md` — Optional object storage
- `.claude/deployment.md` — Rails deployment
