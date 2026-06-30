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

MyApp deploys to a **single Ubuntu droplet on DigitalOcean** running the release
as a Docker Compose stack. The pieces, all provisioned by the bootstrap:

| Concern | Implementation |
|---|---|
| Compute | One Ubuntu droplet running Docker Compose (cloud-init installs Docker only — no secrets) |
| TLS | **Caddy** terminates TLS, auto-issues + renews a Let's Encrypt cert (HTTP-01/TLS-ALPN), reverse-proxies to the app container |
| Database | DigitalOcean Managed Postgres, **private-VPC only**, TLS **verified** against the cluster CA (`verify_peer`) |
| DNS | An A record at DNSimple → a **reserved IP** that survives droplet recreation |
| Images | Built on GitHub's amd64 runners, pushed to **DO Container Registry (DOCR)**, **SHA-pinned** |
| Releases | An `app_blue`/`app_green` pair behind Caddy — exactly one live at a time (zero-downtime swap) |

There is **no `fly.toml`/`render.yaml`-style host config file**. The runtime shape
lives in `deploy/compose.yaml` (the blue/green + Caddy stack) and `deploy/Caddyfile`
(TLS + reverse proxy), both shipped to the droplet at deploy time. Per-deploy values
(image ref, domain, secrets) arrive in a `.env` written over SSH — never committed.

### Why this setup

- Cheap and predictable: one droplet + one managed DB cluster, no per-request edge pricing.
- Caddy gives automatic HTTPS with zero cert plumbing.
- Blue/green on a single host gives zero-downtime deploys without an orchestrator.
- The DB lives in a managed cluster, so destroying/recreating the droplet never risks data.

> **Single-node by design.** This is one droplet — no Erlang clustering. `dns_cluster`
> is wired in the supervision tree but resolves to `:ignore` (no `DNS_CLUSTER_QUERY`
> set). If you later run multiple nodes, see *Clustering* below — but most small apps
> never need it.

---

## Secrets Management

### Never commit secrets

Production secrets live as **GitHub Actions repository secrets**. The deploy
workflow writes them into a **mode-600 `.env`** on the droplet over SSH at deploy
time, and Docker Compose loads that file into the container (`env_file: .env`).
Nothing secret is ever in cloud-init, droplet metadata, the image, source code,
`config/` files, or logs. `runtime.exs` reads them at boot.

The public DB cluster CA travels the same path but is **not** secret — it ships as
`db-ca.pem` (mode 644) next to `compose.yaml` and is mounted read-only so the app
can verify the Postgres server cert.

### Example environment variables

These reach the container via `.env` (secrets) or the compose `environment:` block
(non-secret runtime config):

| Variable                          | Purpose                                                        |
|-----------------------------------|----------------------------------------------------------------|
| `DATABASE_URL`                    | Postgres connection string (private-VPC host; a TF sensitive output) |
| `SECRET_KEY_BASE`                 | Phoenix secret key                                             |
| `PHX_HOST` / `DOMAIN`             | Public FQDN — URL host + the cert/Caddy site name             |
| `PHX_SERVER`                      | `"true"` so the endpoint actually serves (set in compose)     |
| `PORT`                            | App listen port (`4000`, internal-only; Caddy proxies to it)  |
| `DATABASE_CA_FILE`                | Path to the mounted cluster CA (`/app/db-ca.pem`) — triggers `verify_peer` |
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

`MyApp.Release.migrate/0` must exist and work correctly. The deploy workflow runs
it as a **one-off container before the blue/green swap** — a gate, so traffic never
hits a half-migrated DB:

```shell
docker compose run --rm migrate bin/my_app eval 'MyApp.Release.migrate()'
```

A non-zero exit fails the deploy and the old release keeps serving.

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

## Host Configuration (the droplet stack)

Runtime config lives in two files shipped to the droplet at deploy time, plus a
per-deploy `.env`. No PaaS config file.

### `deploy/compose.yaml` essentials

The blue/green pair share one definition. Non-secret runtime config is set in the
`environment:` block; secrets come from `.env`:

```yaml
x-app: &app
  image: ${IMAGE}              # SHA-pinned, from .env
  restart: unless-stopped
  env_file: [.env]             # DATABASE_URL, SECRET_KEY_BASE, ...
  environment:
    PHX_SERVER: "true"         # endpoint serves only when set (runtime.exs)
    PHX_HOST: ${DOMAIN}        # URL host + Endpoint :url
    PORT: "4000"               # internal only — never published to the host
    DATABASE_CA_FILE: /app/db-ca.pem   # presence flips the Repo to verify_peer
  volumes:
    - ./db-ca.pem:/app/db-ca.pem:ro
  expose: ["4000"]             # Caddy reaches it by service name on the compose net

services:
  app_blue: *app
  app_green: *app
  migrate: { <<: *app, restart: "no", profiles: ["tools"] }   # one-off migration runner
  caddy: # ports 80/443, mounts ./Caddyfile, persists certs in a volume
```

> **No `ECTO_IPV6`/`ERL_AFLAGS` here.** Those exist for IPv6-only private networks
> (a Fly-ism). This setup talks to Postgres over the droplet's **IPv4 private VPC**
> and runs a **single node**, so there's no IPv6 distribution and no `RELEASE_NODE`
> to make unique. Don't copy those vars in.

### `deploy/Caddyfile` essentials

Naming the site by its public domain triggers Caddy's automatic HTTPS (Let's
Encrypt over HTTP-01/TLS-ALPN). Both colors are listed; a dial to the stopped
color fails fast and Caddy retries the live one, holding requests through the swap:

```caddyfile
{$DOMAIN} {
	reverse_proxy app_blue:4000 app_green:4000 {
		lb_try_duration 30s
		lb_try_interval 250ms
		fail_duration 10s
	}
}
```

### Clustering (optional — not used here)

This is a single droplet, so clustering is off: `DNSCluster` is in the tree but
its query resolves to `:ignore`. If you later scale to multiple nodes behind DNS,
re-enable it:

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
   (`DNS_CLUSTER_QUERY`) to peer IPs, connecting to each. Covers any host that
   exposes peer nodes via DNS (Kubernetes headless services, multi-droplet behind
   a private DNS name, etc.). Reach for nothing else first.
2. **Escalate to `libcluster`** only when DNS discovery is insufficient or you
   need a topology DNS can't express:
   - **`Cluster.Strategy.Kubernetes`** — query the k8s API directly (pods not
     fronted by a headless service, or label-based selection).
   - **`Cluster.Strategy.Gossip`** — UDP multicast on networks without stable DNS.
   - **`Cluster.Strategy.Epmd`** — a fixed, statically-known node list.

> Source: [BEAM clustering made easy](https://fly.io/phoenix-files/beam-clustering-made-easy/).

### Health checks

The deploy's correctness hinges on a **container healthcheck**, not a platform
health probe.

**How the swap uses health here.** The new color's container has a Docker
`healthcheck`; the deploy runs `docker compose up -d --wait <new color>`, which
**blocks until that healthcheck passes** before `swap.sh` stops the old color. If
it never turns healthy the deploy fails and the old color keeps serving — that's
the zero-downtime guarantee. So get the container healthcheck right:

- **`start_period` must exceed BEAM startup time.** The BEAM, Ecto pool, and
  endpoint take a few seconds to come up; failures during `start_period` don't
  count against `retries`. The stack ships `start_period: 10s` — raise it for big
  release boots.
- **The shipped check is a bare liveness probe** (the endpoint answers HTTP at
  all, any status — apps often redirect `/`), via `bash`+`/dev/tcp` because the
  slim runtime image has no curl/wget:

  ```yaml
  # deploy/compose.yaml
  healthcheck:
    test: ["CMD", "bash", "-c", "exec 3<>/dev/tcp/127.0.0.1/4000 && printf 'HEAD / HTTP/1.0\r\nHost: localhost\r\n\r\n' >&3 && grep -q 'HTTP/' <&3"]
    interval: 5s
    timeout: 3s
    retries: 12
    start_period: 10s
  ```

If you want a **deeper** readiness signal (DB reachable, not just listening), add a
dedicated `/health` endpoint and point the check at it. **Use `/health`, not `/`**
— `/` is often a heavy page or a LiveView (a poor liveness signal). If you do, also
exempt `/health` from `force_ssl` HSTS redirects, or the probe sees a 3xx and fails:

```elixir
# config/runtime.exs — exclude the health path from the HSTS/redirect plug
config :my_app, MyAppWeb.Endpoint,
  force_ssl: [rewrite_on: [:x_forwarded_proto], exclude: ["/health"]]
```

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

The shipped `.github/workflows/deploy.yml` is a **three-job pipeline** — every push
to `main` runs it, and the first push (from the bootstrap) is just the first run:

```yaml
# .github/workflows/deploy.yml  (shape — see the real file for full steps)
name: deploy
on: { push: { branches: [main] } }
concurrency: { group: deploy-${{ github.ref }}, cancel-in-progress: false }  # never overlap
env: { REGISTRY: registry.digitalocean.com }

jobs:
  # 1. GATE — red tests block everything downstream.
  test:
    runs-on: ubuntu-latest
    services:
      postgres: { image: postgres:17-alpine, ... }   # mix test runs against this
    steps:
      - uses: actions/checkout@v6
      - uses: erlef/setup-beam@v1          # Elixir/OTP pins parsed from the Dockerfile ARGs
      - run: mix deps.get
      - run: mix test

  # 2. BUILD — native amd64 image (no QEMU), SHA-pinned, pushed to DOCR.
  build:
    needs: test
    runs-on: ubuntu-latest
    steps:
      - uses: digitalocean/action-doctl@v2     # token: secrets.DIGITALOCEAN_ACCESS_TOKEN
      - run: doctl registry login --expiry-seconds 1200
      - uses: docker/build-push-action@v7      # tags: <registry>/<DOCR_REGISTRY>/<app>:${{ github.sha }}

  # 3. DEPLOY — deliver over SSH, migrate (gated), blue/green swap.
  deploy:
    needs: build
    runs-on: ubuntu-latest
    steps:
      # Port 22 is closed to the world; punch a /32 hole for THIS runner...
      - run: doctl compute firewall add-rules ${{ vars.FIREWALL_ID }} --inbound-rules "...address:${runner_ip}/32"
      # write a mode-600 .env (IMAGE, DOMAIN, DATABASE_URL, SECRET_KEY_BASE) + db-ca.pem
      # scp deploy/{compose.yaml,Caddyfile,swap.sh} + .env + db-ca.pem to root@droplet
      - run: ssh root@$HOST "cd /root && docker compose pull"
      - run: ssh root@$HOST "docker compose run --rm migrate bin/<app> eval '<Module>.Release.migrate()'"  # gate
      - run: ssh root@$HOST "bash /root/swap.sh"          # health-checked blue/green swap
      - if: always()                                       # ...revoked no matter how the deploy ended
        run: doctl compute firewall remove-rules ${{ vars.FIREWALL_ID }} --inbound-rules "...address:${RUNNER_IP}/32"
```

Rollback is a separate `rollback.yml`: `gh workflow run rollback.yml -f tag=<prev sha>`
re-points `.env` at a prior SHA-pinned image and re-swaps — **no rebuild**.

Required repo config (seeded by the bootstrap):
- secrets: `DIGITALOCEAN_ACCESS_TOKEN`, `SSH_PRIVATE_KEY`, `DATABASE_URL`, `DATABASE_CA_CERT`, `SECRET_KEY_BASE`
- variables: `DOCR_REGISTRY`, `DOMAIN`, `DROPLET_HOST`, `FIREWALL_ID`

### Rules

- The `build` job declares `needs: test` and `deploy` declares `needs: build` —
  **a red test blocks the build, which blocks the deploy.** Non-negotiable.
- **The migration step is a gate**: it runs the new image as a one-off *before* the
  swap. A failed migration fails the job, the swap is skipped, and the old release
  keeps serving — a bad migration can never front a half-updated DB.
- **Images are SHA-pinned** (`:${{ github.sha }}`), built on **native amd64 runners**
  — no QEMU, no Apple-Silicon cross-build architecture mismatch.
- **The SSH hole-punch is revoked in an `always()` step** — even on failure. The
  `deploy` concurrency group (`cancel-in-progress: false`) means at most one hole
  exists at a time and an in-flight deploy is never interrupted.
- **Recommended additions to the `test` job** (not in the generated baseline — add
  them as the app matures): `mix compile --warnings-as-errors`, `mix format --check-formatted`,
  `mix credo --strict`, `mix dialyzer`, `mix deps.audit` (lockfile CVEs), `mix hex.audit`
  (retired packages), `mix sobelow --exit` (Phoenix security scan), `npx tsc --noEmit`
  (TS hooks), `mix assets.deploy`. Source: [Sobelow](https://github.com/nccgroup/sobelow).

---

## Cross-references

- External service integration patterns (media/video provider): `external-service-integration.md`
- Payment provider integration patterns: `payment-integration.md`
- Object storage integration patterns: `object-storage-integration.md`

---

## What Not to Do in Deployment

- **No `mix` commands on the server** — use release commands only
- **No secrets in `config/config.exs` or `config/prod.exs`** — runtime only
- **No deploys that skip tests** — the `test → build → deploy` gate chain is not optional
- **No direct pushes that bypass the workflow** — always push to `main` and
  let the workflow run; never `scp`/`ssh` a build onto the droplet by hand
- **No hardcoded hostnames** — `PHX_HOST`/`DOMAIN` come from the environment
- **No `ECTO_IPV6`/`ERL_AFLAGS`/`RELEASE_NODE`** — those are for IPv6-only private
  networks and multi-node clustering. This is a single node on an IPv4 private VPC;
  copying them in just breaks things
- **No committing secrets or the `.env`** — secrets are GitHub Actions secrets,
  delivered to a mode-600 `.env` over SSH at deploy time
- **No `force_ssl` redirect on the health path** if you add a `/health` endpoint,
  and never point a health check at `/` or a LiveView route
