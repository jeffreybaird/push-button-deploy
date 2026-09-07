# push-button-deploy

One command takes you from an **empty directory** to a **freshly generated Phoenix app, Sinatra app or Zola site serving HTTPS on a production DigitalOcean droplet**, with a CI/CD pipeline that deploys every push to `main` from that moment on. Pick the stack with `FRAMEWORK` (default `phoenix`; see [Frameworks](docs/frameworks.md)).

```bash
./bootstrap.sh ~/src/myapp
# ... a few minutes later ...
# ==> LIVE: https://myapp.example.com
```

If `~/src/myapp` doesn't exist (or is empty), a new app is generated there for the chosen `FRAMEWORK`. If it already contains an app (a `mix.exs` for Phoenix, a `Gemfile` for Sinatra, a `config.toml` for Zola), that app is used as-is — so you can point it at output from your own generator instead.

**Not everything worth building is a website.** `--cli` and `--no-droplet` build a command-line
program or a reusable package instead: same repo creation, same pipeline wiring, same one
command — but no droplet, no DNS, no database, and no DigitalOcean credentials required at all.
Pick the CLI's language on the same flag. See [App types](docs/app-types.md).

```bash
./bootstrap.sh --cli ruby       ~/src/mytool   # also: elixir, bash, typescript
./bootstrap.sh --cli typescript ~/src/myothertool
./bootstrap.sh --no-droplet     ~/src/mylib    # a package, built and tested by CI
```

Every CLI it generates is a **command**, not a script you configure by exporting variables:

```bash
mytool --format json hello there    # not FORMAT=json ./mytool.sh hello there
```

## What you get

| Concern | Implementation |
|---|---|
| Compute | One Ubuntu droplet running Docker Compose — which can host **several apps** (see [Tenancy](docs/tenancy.md)) |
| TLS | Caddy with automatic Let's Encrypt issuance + renewal |
| Database | DigitalOcean Managed Postgres, private-VPC only, TLS **verified** against the cluster CA (`verify_peer`) — or SQLite (see [Databases](docs/databases.md)) |
| DNS | A record at DNSimple pointing at a reserved IP that survives droplet recreation |
| Images | Built on amd64 CI runners (GitHub-hosted, or your own for Gitea — see [Gitea](docs/gitea.md)), pushed to DO Container Registry, SHA-pinned |
| Deploys | Every push to `main`: test (gate) → build → migrate (gated) → health-checked blue/green swap (zero downtime) |
| Staging | Every PR against `main`: a full environment on the same droplet at `<app>-stg.<zone>`, destroyed when the PR closes (see [Staging](docs/staging.md)) |
| Tests | `mix test` against a Postgres 17 service container; red tests block the build and deploy |
| Rollback | Pins a prior image, no rebuild — `gh workflow run rollback.yml -f tag=<previous sha>` (GitHub) or the Actions tab (Gitea) |
| Migrations | Run via a release task **before** traffic switches; a failed migration leaves the old release serving |
| Claude Code docs | Every generated app ships a `CLAUDE.md` + `.claude/` (guidance modules, starter agents, a SessionStart hook) — see [Claude Code docs](docs/claude-docs.md) |
| Terraform state | Versioned DO Spaces bucket (S3-compatible backend) |
| Secrets | Never in cloud-init or droplet metadata — they arrive over SSH at deploy time |

The three-Terraform-root architecture, host-owned Caddy, blue/green swap and
compute/data lifecycle isolation are explained in [Concepts](docs/concepts.md).

## Get started

1. Install the tools and set your credentials — [Prerequisites](docs/prerequisites.md).
2. Follow the [Quickstart](docs/quickstart.md): empty directory to live HTTPS, step by step.

```bash
./bootstrap.sh --check ~/src/myapp   # verify prerequisites; provisions nothing
./bootstrap.sh ~/src/myapp           # go
./bootstrap.sh --interactive         # or be prompted for every choice, then deploy
```

## Documentation

The full guide lives in [`docs/`](docs/index.md).

| Page | What it covers |
|---|---|
| [Concepts](docs/concepts.md) | Architecture and mental model: app types × frameworks, the Terraform roots, blue/green, Caddy, lifecycle isolation |
| [Prerequisites](docs/prerequisites.md) | Required tools, accounts and credentials, the full `.env` reference, `--check` |
| [Quickstart](docs/quickstart.md) | A single service from empty directory to live HTTPS — plus a droplet-free quickstart |
| [App types](docs/app-types.md) | `service` / `cli` / `library`, the language↔framework table, and interactive selection |
| [Frameworks](docs/frameworks.md) | Phoenix, Sinatra and Zola specifics — generation, CI gate, migrations, image/release |
| [Databases](docs/databases.md) | SQLite (Litestream) vs managed Postgres — tradeoffs and conversion caveats |
| [Staging](docs/staging.md) | Per-PR staging environments — how they work and how to turn them off |
| [Tenancy](docs/tenancy.md) | Several apps on one droplet — host apps and tenants |
| [Gitea](docs/gitea.md) | Self-hosted Gitea as code host and CI engine |
| [Claude Code docs](docs/claude-docs.md) | Generating and tailoring an app's `CLAUDE.md` + `.claude/` |
| [Operations](docs/operations.md) | Day-2: deploy, watch, roll back, recreate, add an app, tear down |
| [Troubleshooting](docs/troubleshooting.md) | Symptom → fix table and FAQ |
| [Reference](docs/reference.md) | Commands, flags, env vars, scripts, Terraform roots, costs, security |

`DIRECTIONS.md` is the original build spec (historical); the docs above describe the tool as it is today.
