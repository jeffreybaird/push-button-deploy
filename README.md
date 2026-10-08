# push-button-deploy

One command takes you from an **empty directory** to a **freshly generated Phoenix app, Sinatra app, Rails app, Zola site or frontend-only React app serving HTTPS on a production DigitalOcean droplet**, with a CI/CD pipeline that deploys every push to `main` from that moment on. Pick the stack with `FRAMEWORK` (default `phoenix`; see [Frameworks](docs/frameworks.md)).

```bash
./bootstrap.sh ~/src/myapp
# ... a few minutes later ...
# ==> LIVE: https://myapp.example.com
```

If `~/src/myapp` doesn't exist (or is empty), a new app is generated there for the chosen `FRAMEWORK`. An existing app with the selected framework's marker (`mix.exs`, `Gemfile`, `config/application.rb`, `config.toml`, or a validated React `package.json`) skips generation. Bootstrap still prepares release files, installs deployment templates, and adopts agent docs if no lifecycle manifest exists. Review and commit local work first: bootstrap stages all app changes when committing the pipeline.

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

Generate a generic React + TypeScript frontend and deploy it with either code host:

```bash
FRAMEWORK=react ./bootstrap.sh ~/src/my-frontend
# Local scaffold only (no cloud provisioning):
./scripts/new-react-app.sh ~/src/my-frontend
```

The starter is intentionally small: extend its components into your application.
See [React requirements and deployment](docs/frameworks.md#react).

## What you get

| Concern | Implementation |
|---|---|
| Compute | One Ubuntu droplet running Docker Compose — which can host **several apps** (see [Tenancy](docs/tenancy.md)) |
| TLS | Caddy with automatic Let's Encrypt issuance + renewal |
| Database | SQLite by default, replicated to Spaces; Phoenix can instead use managed Postgres with private-VPC access and verified TLS. Zola and React have no database. See [Databases](docs/databases.md). |
| DNS | A record at DNSimple pointing at a reserved IP that survives droplet recreation |
| Images | Built on amd64 CI runners (GitHub-hosted, or your own for Gitea — see [Gitea](docs/gitea.md)), pushed to DO Container Registry, SHA-pinned |
| Deploys | Dynamic services: tests → image build → migrations → health-checked blue/green swap. Zola and React build and publish files by symlink. CLI/library apps run build/test CI. |
| Staging | GitHub dynamic services share one PR slot per app at `<app>-stg.<zone>`; closing the owning PR removes it. See [Staging](docs/staging.md). |
| Tests | Phoenix: ExUnit and strict Cucumberex (CI also starts Postgres 17); Sinatra: RSpec and strict Cucumber; Rails starters: RSpec, Cucumber, coverage and RuboCop; Elixir CLI/library starters: ExUnit and strict Cucumberex; Zola: build gate; React: Vitest and typechecked Vite build. |
| Rollback | Dynamic services repin an existing image; Static apps select a retained release. `gh workflow run rollback.yml -f tag=<previous-sha>` or the Gitea Actions tab. No database rollback. |
| Migrations | Run via a release task **before** traffic switches; a failed migration leaves the old release serving |
| Agent docs | Every generated app ships managed Codex and Claude guidance, workflow roles, and hooks; `agent-docs.sh` handles future updates — see [Agent docs](docs/claude-docs.md) |
| Terraform state | Versioned DO Spaces bucket (S3-compatible backend) |
| Secrets | Never in cloud-init or droplet metadata — they arrive over SSH at deploy time |

The three-Terraform-root architecture, host-owned Caddy, blue/green swap and
compute/data lifecycle isolation are explained in [Concepts](docs/concepts.md).

## Get started

Use a checkout of this repository. Homebrew packaging is being developed
separately; this branch does not yet provide a `pbd` executable or formula.

1. Install the tools and set your credentials — [Prerequisites](docs/prerequisites.md).
2. Follow the [Quickstart](docs/quickstart.md): empty directory to live HTTPS, step by step.

```bash
./bootstrap.sh --check ~/src/myapp   # verify prerequisites; provisions nothing
./bootstrap.sh ~/src/myapp           # go
./bootstrap.sh --interactive         # or be prompted for every choice, then deploy
```

After generation, manage shared agent guidance independently of deployment:

```bash
./agent-docs.sh check ~/src/myapp
./agent-docs.sh diff ~/src/myapp
./agent-docs.sh update ~/src/myapp
```

Keep app-specific rules in `.docs/project-guidance.md`. See [Agent docs](docs/claude-docs.md)
for configuration, drift handling, and the preserved legacy frontend.

## Documentation

The full guide lives in [`docs/`](docs/index.md).

| Page | What it covers |
|---|---|
| [Concepts](docs/concepts.md) | Architecture and mental model: app types × frameworks, the Terraform roots, blue/green, Caddy, lifecycle isolation |
| [Prerequisites](docs/prerequisites.md) | Required tools, accounts and credentials, the full `.env` reference, `--check` |
| [Quickstart](docs/quickstart.md) | A single service from empty directory to live HTTPS — plus a droplet-free quickstart |
| [App types](docs/app-types.md) | `service` / `cli` / `library`, the language↔framework table, and interactive selection |
| [Frameworks](docs/frameworks.md) | Phoenix, Sinatra, Rails, Zola and React specifics — generation, CI gate, migrations, image/release |
| [Databases](docs/databases.md) | SQLite (Litestream) vs managed Postgres — tradeoffs and conversion caveats |
| [Staging](docs/staging.md) | Per-PR staging environments — how they work and how to turn them off |
| [Tenancy](docs/tenancy.md) | Several apps on one droplet — host apps and tenants |
| [Gitea](docs/gitea.md) | Self-hosted Gitea as code host and CI engine |
| [Agent docs](docs/claude-docs.md) | Generating, configuring, and updating shared agent guidance throughout an app's life |
| [Operations](docs/operations.md) | Day-2: deploy, watch, roll back, recreate, add an app, tear down |
| [Troubleshooting](docs/troubleshooting.md) | Symptom → fix table and FAQ |
| [Reference](docs/reference.md) | Commands, flags, env vars, scripts, Terraform roots, costs, security |

`DIRECTIONS.md` is the original build spec (historical); the docs above describe the tool as it is today.

## Development

Run the deployment tool's offline regression tests with `bash test/run.sh`.
The same suite runs for pull requests on Linux and macOS. See
[Test coverage and contribution guidance](test/README.md) for prerequisites,
covered behavior, isolation rules, and the limits of offline verification.

### Preview teardown

Run `./teardown.sh --plan /path/to/app` to inspect the host, tenant, or
repository-only scope without remote calls. See [teardown design](scripts/teardown/README.md).
