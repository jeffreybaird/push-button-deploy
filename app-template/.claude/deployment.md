# Deployment

Load this file when working on CI/CD, host configuration, Dockerfiles,
release scripts, or environment configuration.

> **Baseline:** Phoenix 1.8 (Bandit) · mix releases · OTP 27. Scaffold releases
> with `mix phx.gen.release`.

When adding deps mentioned here, pin exact versions (`==`) for reproducible
builds — don't let `~>` ranges drift between machines and deploys. Bump pins
deliberately in a dedicated, reviewed commit and let CI catch regressions. Pre-1.0
packages are especially volatile, so exact-pin them too (e.g. `== 0.3.0`).

---

## Platform

MyApp can deploy to any hosting provider that supports Elixir releases. Common
choices include Fly.io, Render, Gigalixir, or a self-managed server. Configuration
for your chosen host typically lives in a root-level config file (e.g. `fly.toml`
for Fly.io, a `render.yaml` for Render, etc.).

### Why a PaaS

- Managed Postgres with automatic failover
- Native Elixir clustering support (e.g. DNS-based node discovery via `dns_cluster` on Fly.io)
- Low-latency edge routing benefits LiveView WebSocket connections
- Simple multi-region deployment

> **Fly.io note:** Fly.io supports Erlang clustering via its internal DNS.
> Instances discover each other via `<app-name>.internal`. Other providers
> may require alternative clustering strategies (e.g. libcluster with an
> Epmd or Kubernetes strategy).

---

## Secrets Management

### Never commit secrets

All production secrets must be injected at runtime via your host's secret
management (e.g. `fly secrets set KEY=VALUE` on Fly.io, environment variables
on Render/Gigalixir). They must never appear in source code, `config/` files,
or be logged.

### Example environment variables

| Variable                          | Purpose                                                        |
|-----------------------------------|----------------------------------------------------------------|
| `DATABASE_URL`                    | Postgres connection string                                     |
| `SECRET_KEY_BASE`                 | Phoenix secret key                                             |
| `PHX_HOST`                        | Primary hostname                                               |
| `RELEASE_COOKIE`                  | Erlang distribution cookie (required for clustering)           |
| `VIDEO_PROVIDER_TOKEN_ID`         | API credential for your media/video provider                   |
| `VIDEO_PROVIDER_TOKEN_SECRET`     | API credential for your media/video provider                   |
| `VIDEO_PROVIDER_WEBHOOK_SECRET`   | Webhook signing secret for your media/video provider           |
| `PAYMENT_PROVIDER_SECRET_KEY`     | API key for your payment provider                              |
| `PAYMENT_PROVIDER_WEBHOOK_SECRET` | Webhook signing secret for your payment provider               |
| `OBJECT_STORE_KEY_ID`             | Key ID for your S3-compatible object store                     |
| `OBJECT_STORE_SECRET`             | Secret for your S3-compatible object store                     |
| `OTEL_EXPORTER_OTLP_ENDPOINT`     | OTLP gateway URL for tracing (optional)                        |
| `OTEL_EXPORTER_OTLP_AUTH_HEADER`  | Auth header for OTLP exporter (optional)                       |
| `MAILER_API_KEY`                  | API key for transactional email provider                       |
| `MAILER_FROM`                     | Default from address for emails                                |

### `config/runtime.exs` is the only place for prod config

All production configuration reads from `System.fetch_env!/1`. Use the bang
variant so missing vars fail loudly at boot rather than silently misbehaving.

```elixir
# ✅ CORRECT — fails loudly if missing
config :my_app, :video_token_id, System.fetch_env!("VIDEO_PROVIDER_TOKEN_ID")

# ❌ WRONG — silently nil if missing
config :my_app, :video_token_id, System.get_env("VIDEO_PROVIDER_TOKEN_ID")
```

---

## Release

### Scaffold with `mix phx.gen.release`

Generate the Release module and helper scripts rather than hand-writing them:

```shell
# Plain mix release (generates lib/my_app/release.ex + rel/overlays/bin scripts)
mix phx.gen.release

# Add a Dockerfile + .dockerignore for container-based hosts
mix phx.gen.release --docker
```

This produces `MyApp.Release` (the module shown below), plus `rel/overlays/bin/migrate`
and `rel/overlays/bin/server` scripts that wrap `eval`/`start` so your host can call
a single command. The hand-written module below is exactly what the task scaffolds —
treat it as the reference shape, not something to author from scratch.

> Sources: [Phoenix releases guide](https://phoenix.hexdocs.pm/releases.html),
> [`mix phx.gen.release`](https://hexdocs.pm/phoenix/Mix.Tasks.Phx.Gen.Release.html).

### The Release module is required

`MyApp.Release.migrate/0` must exist and work correctly. It is called by
the host's deployment process (or your own deploy script) before the service
starts accepting traffic.

```elixir
defmodule MyApp.Release do
  @app :my_app

  def migrate do
    load_app()
    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos, do: Application.fetch_env!(@app, :ecto_repos)
  defp load_app, do: Application.ensure_all_started(:ssl)
end
```

### Never use `mix` in production

Release commands only. `mix ecto.migrate` requires the Mix toolchain which is
not present in a compiled release.

```shell
# ✅ CORRECT — release command
/app/bin/my_app eval "MyApp.Release.migrate()"

# ❌ WRONG — requires Mix
mix ecto.migrate
```

---

## OpenTelemetry Instrumentation

A high-level template may defer tracing entirely. But any app implementing the
"Instrument Everything" principle on Phoenix 1.8 must account for one Bandit-specific
gotcha at deploy time.

**If you adopt `opentelemetry_phoenix` 2.0, you MUST also add `opentelemetry_bandit`
(or `opentelemetry_cowboy` if you switched adapters).** Phoenix 1.8 defaults to the
Bandit web server. `OpentelemetryPhoenix` only instruments the Phoenix portion of the
request lifecycle — it does not cover the server-level connection handling that Bandit
performs. Running Phoenix instrumentation alone on Bandit yields **incomplete span
durations and dropped/orphaned traces**. The adapter library closes that gap.

Two non-negotiables for the 2.0 line:

- `OpentelemetryPhoenix.setup(adapter: :bandit)` — the `adapter:` option is **required**
  in 2.0 (a breaking change from 1.x, which inferred it). Call it (along with
  `OpentelemetryBandit.setup()`) **before** the top supervisor starts in `start/2`.
- The endpoint must have `plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]`,
  or `OpentelemetryPhoenix` never receives the event that starts its span.

`opentelemetry_bandit` is pre-1.0 (v0.3.x) — exact-pin it (e.g. `== 0.3.0`). The OTEL exporter
endpoint/auth env vars are already in the secrets table above.

The full bootstrap (deps list, `start/2` wiring, exporter config) lives in
`observability.md` — do not duplicate it here; cross-reference it.

> Sources: [OpentelemetryPhoenix readme](https://opentelemetry-phoenix.hexdocs.pm/readme.html),
> [opentelemetry_phoenix on hex.pm](https://hex.pm/packages/opentelemetry_phoenix).

---

## Host Configuration (Fly.io example)

The patterns below use Fly.io as a concrete example. Adapt env var names and
deployment commands to your chosen host.

### `fly.toml` essentials

```toml
[env]
  PHX_HOST = "myapp.com"
  ECTO_IPV6 = "true"
  ERL_AFLAGS = "-proto_dist inet6_tcp"
  DNS_CLUSTER_QUERY = "myapp.internal"
  RELEASE_DISTRIBUTION = "name"

[deploy]
  release_command = "/app/bin/my_app eval MyApp.Release.migrate"
```

> **These vars are host-specific rationale, not universal.** Fly.io's private
> network (`*.internal`) is IPv6-only, so `ECTO_IPV6 = "true"` makes Ecto
> connect over IPv6 and `ERL_AFLAGS = "-proto_dist inet6_tcp"` makes Erlang
> distribution (clustering) speak IPv6. On an IPv4-only host, drop both. Either
> way, each node needs a **unique** `RELEASE_NODE` (Fly derives it per-machine;
> set it yourself on hosts that don't) — duplicate node names break clustering.
>
> Source: [Fly clustering basics](https://fly.io/docs/elixir/the-basics/clustering/).

### Clustering (optional)

Erlang clustering via `dns_cluster` works natively on Fly.io. Enable it in
your application supervision tree:

```elixir
# In application.ex
children = [
  {DNSCluster, query: Application.get_env(:my_app, :dns_cluster_query) || :ignore},
  {Phoenix.PubSub, name: MyApp.PubSub},
  # ...
]
```

**Decision tree — start simple, escalate only when DNS isn't enough:**

1. **Default: `dns_cluster`.** It ships with Phoenix 1.8 and resolves a query
   (`DNS_CLUSTER_QUERY`, e.g. `myapp.internal`) to peer IPs, connecting to each.
   This covers any host that exposes peer nodes via DNS — Fly.io, Render private
   networking, Kubernetes headless services, etc. Reach for nothing else first.
2. **Escalate to `libcluster`** only when DNS discovery is insufficient or you
   need a topology DNS can't express:
   - **`Cluster.Strategy.Kubernetes`** — query the k8s API directly (pods not
     fronted by a headless service, or label-based selection).
   - **`Cluster.Strategy.Gossip`** — UDP multicast on networks without stable DNS.
   - **`Cluster.Strategy.Epmd`** — a fixed, statically-known node list.

> Sources: [BEAM clustering made easy](https://fly.io/phoenix-files/beam-clustering-made-easy/),
> [Fly clustering](https://fly.io/docs/elixir/the-basics/clustering/).

### Health checks

Health checks should hit a lightweight, dedicated `/health` endpoint that
confirms the app is running and the database is reachable. **Use `/health`, not
`/`** — `/` is often a LiveView or a heavy page, and a LiveView route returns a
WebSocket-upgrade-oriented response that is a poor liveness signal. Never point a
health check at a LiveView route.

```elixir
# A simple plug-based health check
get "/health", HealthController, :check
```

Two deploy-time pitfalls cause zombie machines (the platform kills a node that
was actually healthy, then restarts it in a loop):

- **`grace_period` must exceed BEAM startup time.** The BEAM, Ecto pool, and
  endpoint take a few seconds to come up. If the platform starts probing before
  the app is listening, the first checks fail and the machine is killed. Set
  `grace_period` generously (≥ 10s; longer for big release boots).
- **Exempt `/health` from `force_ssl` HSTS redirects.** Internal health probes
  hit the node over plain HTTP on the private network. If `force_ssl` 301-redirects
  `/health` to `https://`, the probe sees a 3xx (not 2xx) and fails. Scope the
  redirect so `/health` is excluded:

  ```elixir
  # config/runtime.exs — exclude the health path from the HSTS/redirect plug
  config :my_app, MyAppWeb.Endpoint,
    force_ssl: [rewrite_on: [:x_forwarded_proto], exclude: ["/health"]]
  ```

A concrete Fly.io check block (adapt field values to your host):

```toml
# fly.toml
[[http_service.checks]]
  grace_period = "10s"   # wait for the BEAM/endpoint to boot before probing
  interval     = "30s"   # time between checks
  timeout      = "5s"    # max time a check may take before it's failing
  method       = "GET"
  path         = "/health"
```

> Sources: [Fly health checks](https://fly.io/docs/reference/health-checks/),
> [zombie machines from a failing Phoenix health check](https://community.fly.io/t/custom-health-check-on-phoenix-fails-and-creates-zombie-machines/18932).

---

## Read Replicas (optional scaling pattern)

**Most apps run a single primary — ship that first.** Not providing concrete
replica wiring here is intentional: architecture principle #2 keeps read and write
paths separable so that adopting replicas is a later *config* change, not a rewrite.

When read load justifies it, follow Ecto's replica / dynamic-repo pattern rather
than inventing your own:

- Define one or more `read_only: true` replica repos, each with its own connection
  string (`DATABASE_REPLICA_URL`, etc.) injected via `runtime.exs`.
- Route reads to a replica with `Enum.random/1` over the configured replicas; keep
  writes on the primary.
- In tests, set `:default_dynamic_repo` so replica calls resolve to the primary
  (no separate test DB needed).

> Source: [Ecto: replicas and dynamic repositories](https://ecto.hexdocs.pm/replicas-and-dynamic-repositories.html).

---

## CI/CD: GitHub Actions

### Workflow structure

```yaml
# .github/workflows/deploy.yml
name: CI & Deploy

on:
  push:
    branches: [main]

jobs:
  test:
    runs-on: ubuntu-latest
    services:
      postgres:
        image: postgres:16
        # ...
    steps:
      - uses: actions/checkout@v4
      - uses: erlef/setup-beam@v1
      - run: mix deps.get
      - run: mix compile --warnings-as-errors
      - run: mix format --check-formatted
      - run: mix credo --strict
      - run: mix dialyzer
      - run: mix deps.audit          # mix_audit — fails on deps with known CVEs
      - run: mix hex.audit           # built-in Hex — fails on retired packages
      - run: mix sobelow --exit      # static security scan; --exit fails on findings
      - run: npx tsc --noEmit --project assets/tsconfig.json
      - run: mix test
      - run: mix assets.deploy

  deploy:
    needs: test
    runs-on: ubuntu-latest
    if: github.ref == 'refs/heads/main'
    steps:
      - uses: actions/checkout@v4
      # Example: Fly.io deploy step
      - uses: superfly/flyctl-actions/setup-flyctl@master
      - run: flyctl deploy --remote-only
        env:
          FLY_API_TOKEN: ${{ secrets.FLY_API_TOKEN }}
      # For other hosts, replace the two steps above with your host's deploy action or CLI
```

### Rules

- The `deploy` job must declare `needs: test` — deploys never run if tests fail
- `mix compile --warnings-as-errors` treats warnings as failures
- `mix credo --strict` enforces code quality
- Security audits gate alongside tests/format/credo/dialyzer:
  `mix deps.audit` (the `mix_audit` package — scans the lockfile for dependencies
  with known CVEs), `mix hex.audit` (built-in Hex command — flags retired/deprecated
  packages), and `mix sobelow --exit` (static analysis for common Phoenix security
  flaws; `--exit` makes findings fail the build). These are distinct tools — keep
  all three. Sources:
  [Fly Elixir CI/CD](https://fly.io/docs/elixir/advanced-guides/github-actions-elixir-ci-cd/),
  [Sobelow](https://github.com/nccgroup/sobelow).
- `npx tsc --noEmit` type-checks TypeScript hooks without emitting files
- `mix assets.deploy` compiles assets in CI, not on the server
- Migrations run via the host's release command hook, before the new version
  starts serving traffic
- On Fly.io, use `--remote-only` to use Fly's remote builder and avoid
  architecture mismatches (especially on Apple Silicon)

---

## Cross-references

- External service integration patterns (media/video provider): `external-service-integration.md`
- Payment provider integration patterns: `payment-integration.md`
- Object storage integration patterns: `object-storage-integration.md`

---

## What Not to Do in Deployment

- **No `mix` commands on the server** — use release commands only
- **No secrets in `config/config.exs` or `config/prod.exs`** — runtime only
- **No deploys that skip tests** — the `needs: test` gate is not optional
- **No direct pushes that bypass the workflow** — always push to `main` and
  let the workflow run
- **No hardcoded hostnames** — `PHX_HOST` comes from the environment
- **No ignoring host-specific network settings** — `ECTO_IPV6` and `ERL_AFLAGS`
  exist specifically for Fly.io's IPv6 private network; required there, dropped on
  IPv4-only hosts. Don't copy them blindly, and don't omit a unique `RELEASE_NODE`
  per node
- **No health check on `/` or a LiveView route, and no `force_ssl` redirect on
  `/health`** — use a dedicated `/health` endpoint with an adequate `grace_period`
