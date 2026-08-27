# push-button-deploy

One command takes you from an **empty directory** to a **freshly generated Phoenix app, Sinatra app or Zola site serving HTTPS on a production DigitalOcean droplet**, with a CI/CD pipeline that deploys every push to `main` from that moment on. Pick the stack with `FRAMEWORK` (default `phoenix`; see [Application framework](#application-framework)).

```bash
pbd bootstrap ~/src/myapp
# ... a few minutes later ...
# ==> LIVE: https://myapp.example.com
```

If `~/src/myapp` doesn't exist (or is empty), a new app is generated there for the chosen `FRAMEWORK`. If it already contains an app (a `mix.exs` for Phoenix, a `Gemfile` for Sinatra, a `config.toml` for Zola), that app is used as-is — so you can point it at output from your own generator instead.

**Not everything worth building is a website.** `--cli` and `--no-droplet` build a command-line
program or a reusable package instead: same repo creation, same pipeline wiring, same one
command — but no droplet, no DNS, no database, and no DigitalOcean credentials required at all.
Pick the CLI's language on the same flag. See [App types](#app-types).

```bash
pbd bootstrap --cli ruby       ~/src/mytool   # also: elixir, bash, typescript
pbd bootstrap --cli typescript ~/src/myothertool
pbd bootstrap --no-droplet     ~/src/mylib    # a package, built and tested by CI
```

Every CLI it generates is a **command**, not a script you configure by exporting variables:

```bash
mytool --format json hello there    # not FORMAT=json ./mytool.sh hello there
```

...and so is this one. `pbd` holds itself to the standard it holds them to: subcommands,
`--help` on every one of them, `--version`, and exit code 2 for a usage error so a caller
can tell "you typed it wrong" from "it ran and failed".

## Install

```bash
brew install --HEAD ./Formula/pbd.rb      # from a clone
```

Or run it straight out of a checkout — put `bin/pbd` on your PATH and it is the same
command, reading the same templates:

```bash
git clone https://github.com/jeffreybaird/push-button-deploy.git
ln -s "$PWD/push-button-deploy/bin/pbd" ~/.local/bin/pbd
pbd --version
```

Terraform is required and is not in homebrew-core (it is BUSL-licensed):
`brew tap hashicorp/tap && brew install hashicorp/tap/terraform`. `pbd check` names every
other gap before anything is provisioned.

Three paths matter, and `pbd config` prints all of them:

```
$ pbd config
version      0.1.0
root         /opt/homebrew/Cellar/pbd/0.1.0/libexec     # templates + library (read-only)
state        ~/.local/state/pbd                         # transcripts, cached credentials
env file     ~/.config/pbd/env                          # your credentials
```

Nothing is ever written back into `root`, which is what makes the tool installable rather
than a directory you have to `cd` into. Override any of the three with `PBD_ROOT`,
`PBD_STATE_DIR` and `--env-file` — pointing an installed `pbd` at a checkout's templates is
just `PBD_ROOT=~/src/push-button-deploy pbd bootstrap ~/src/myapp`.

The old entry points still work: `./bootstrap.sh`, `./teardown.sh`, `./bootstrap-gitea.sh`
and `./teardown-gitea.sh` forward to the matching subcommand and say so.

### Layout

```
bin/pbd              argument parsing and dispatch, and nothing else
lib/pbd/common.sh    where the tool's files are, where yours go, the env file
lib/pbd/*.sh         one module per command — only the one being run is loaded
scripts/             the generators and shared helpers the commands call out to
infra-*/             Terraform roots, copied into each app's own infra/
app/ deploy/         Dockerfiles, compose stacks, Caddy config, workflows
app-template*/       what a freshly generated app gets on top of its generator
test/run.sh          the whole suite — no framework, drives the real binary
Formula/pbd.rb       the Homebrew formula
```

That split — a thin executable over a library — is the same shape `pbd bootstrap --cli bash`
scaffolds, for the same reason: the library is callable from anywhere, and the parser has one
job.

## What you get

| Concern | Implementation |
|---|---|
| Compute | One Ubuntu droplet running Docker Compose — which can host **several apps** (see [Several apps on one droplet](#several-apps-on-one-droplet)) |
| TLS | Caddy with automatic Let's Encrypt issuance + renewal |
| Database | DigitalOcean Managed Postgres, private-VPC only, TLS **verified** against the cluster CA (`verify_peer`) |
| DNS | A record at DNSimple pointing at a reserved IP that survives droplet recreation |
| Images | Built on amd64 CI runners (GitHub-hosted, or your own for Gitea — see [Gitea support](#gitea-support)), pushed to DO Container Registry, SHA-pinned |
| Deploys | Every push to `main`: test (gate) → build → migrate (gated) → health-checked blue/green swap (zero downtime) |
| Staging | Every PR against `main`: a full environment on the same droplet at `<app>-stg.<zone>`, destroyed when the PR closes (see [Pull-request staging environments](#pull-request-staging-environments)) |
| Tests | `mix test` against a Postgres 17 service container; red tests block the build and deploy |
| Rollback | Pins a prior image, no rebuild — `gh workflow run rollback.yml -f tag=<previous sha>` (GitHub) or the Actions tab (Gitea) |
| Migrations | Run via a release task **before** traffic switches; a failed migration leaves the old release serving |
| Terraform state | Versioned DO Spaces bucket (S3-compatible backend) |
| Secrets | Never in cloud-init or droplet metadata — they arrive over SSH at deploy time |

### Architecture

Three Terraform roots with deliberately separate state:

A **tenant** app (one deployed onto a droplet another app owns) has a fourth,
much smaller root instead of these three — `infra/tenant/`, holding only its DNS
record. See [Several apps on one droplet](#several-apps-on-one-droplet).

```
infra/state/        the Spaces bucket that stores the other two roots' state
                    (its own state is local — chicken/egg — losing it is a
                    non-event: terraform import re-adopts the bucket)

infra/persistent/   VPC, reserved IP, managed Postgres, DNSimple A records (the
                    app's and its staging name's), and a DigitalOcean *project*
                    named after the app that groups its resources in the DO
                    control panel — things that must SURVIVE. prevent_destroy
                    everywhere.

infra/app/          droplet, reserved-IP assignment, firewall
                    — disposable. `terraform destroy` here never touches
                    data: the DB firewall trusts a *tag* the droplet wears,
                    not the droplet itself.
```

**The roots live in the app repo.** The `infra-*/` directories here are
templates; the bootstrap copies them into `<app_dir>/infra/{state,persistent,app}`
and runs Terraform from there, so an app's infrastructure is versioned, reviewed
and rolled back alongside the code that runs on it — changing the deploy is a
commit to the app repo. The copy is **seeded once and never overwritten**, so
local edits survive re-runs; any file that has drifted from the template is
reported so an upstream fix is easy to spot and adopt. To re-seed an app
by hand: `./scripts/sync-infra.sh <app_dir>`.

The droplet runs an `app_blue`/`app_green` pair (exactly one live at a time) behind Caddy. A deploy starts the idle color from the new image, waits for its container healthcheck, then stops the old one; Caddy holds and retries requests across the swap window.

Caddy is **host-owned, not app-owned**: one instance per droplet, in `/root/caddy`, importing a site file per app. Each app's stack lives in `/root/apps/<slug>/` as its own compose project with its own volumes, and the two colors publish `<slug>-blue` / `<slug>-green` aliases on a shared `edge` network for Caddy to dial. That is what makes a second app on the same droplet possible; with one app it is simply the same thing with one site file.

Port 22 is closed to the world. On the default GitHub path, CI punches a temporary `/32` hole for its own (GitHub-hosted, unpredictable) runner IP at the start of each deploy and revokes it in an `always()` step. On the Gitea path (`GIT_PROVIDER=gitea`), the self-hosted Actions runner has a stable IP instead, so it's allow-listed once in Terraform (`GITEA_RUNNER_IP`) rather than punched per-run — see [Gitea support](#gitea-support).

## Prerequisites

### Tools (all checked by `pbd check`)

| Tool | Why | Install (macOS) |
|---|---|---|
| `git` | repo + pushes | xcode-select / brew |
| `terraform` >= 1.6 | provisioning | `brew install terraform` |
| `doctl` | DO registry + firewall ops | `brew install doctl` |
| `gh` | **GitHub only** (default) — repo creation, secrets, run status | `brew install gh` |
| `jq` | **Gitea only** (`GIT_PROVIDER=gitea`) — safe JSON bodies + run-status parsing against the Gitea REST API | `brew install jq` |
| Elixir + `mix` | **Phoenix only** — app generation, deps, secret generation | `brew install elixir` |
| `phx_new` archive | **Phoenix only** — generating the app (needed when the target dir is empty) | `mix archive.install hex phx_new` |
| `openssl` | **Sinatra only** — session-secret generation (the Ruby build runs in Docker/CI, so no local Ruby is required) | preinstalled on macOS |
| `curl`, `ssh`, `scp`, `dig` | plumbing + diagnostics | preinstalled on macOS |

Docker is **not** required locally — images build in CI.

The table above is for a **service** (the default app type). The droplet-free types
(`--cli`, `--no-droplet` — see [App types](#app-types)) need only `git`, `curl` and the code
host's tool (`gh`, or `jq` for Gitea): no Terraform, no `doctl`, no SSH, and **no local runtime
of the language you pick** — every one of those scaffolds is written in bash and built in CI, so
`pbd bootstrap --cli typescript` works on a machine with no Node installed. The credentials
below are likewise service-only; a droplet-free run needs none of them.

### Accounts and credentials (one-time setup)

1. **DigitalOcean**
   - An API token with write access: *API → Tokens → Generate New Token*.
   - A **Spaces keypair** (separate from the API token): *API → Spaces Keys*. Note: Spaces requires the ~$5/mo Spaces subscription, which activates with the first bucket.
   - An SSH key uploaded to the account (*Settings → Security*) — note its **name**.
   - `doctl auth init` (paste the API token).
2. **DNSimple**
   - A zone (domain) hosted there, an API token, and your numeric account ID (visible in the URL or account page).
3. **Code hosting + CI/CD** — `GIT_PROVIDER` picks which (default `github`; see [Gitea support](#gitea-support) for the other).
   - **GitHub** (default): `gh auth login` with permission to create repos and set secrets/variables.
   - **Gitea** (self-hosted, `GIT_PROVIDER=gitea`): a personal access token with repo create/delete and Actions secrets/variables scopes, and — because it also runs the pipeline (Gitea Actions) — a self-hosted runner registered against the instance, with a stable IP you can name in `GITEA_RUNNER_IP`.

### Environment variables

The easiest way: put them in an **env file**. `pbd` looks for one in this order, and
`pbd config` prints which it found:

| Order | Path | For |
|---|---|---|
| 1 | `--env-file PATH` (or `PBD_ENV_FILE`) | naming one explicitly, per run |
| 2 | `${XDG_CONFIG_HOME:-~/.config}/pbd/env` | an installed `pbd` |
| 3 | `$PBD_ROOT/.env` | a checkout you run from |

```bash
mkdir -p ~/.config/pbd
cp .env.example ~/.config/pbd/env && chmod 600 ~/.config/pbd/env
$EDITOR ~/.config/pbd/env
```

The current directory is deliberately **not** searched: app directories carry their own
unrelated `.env` files (the app's own runtime config), and picking one of those up as your
DigitalOcean credentials would provision against the wrong account without saying so.

**The calling shell wins.** A value already set in your environment beats the file, so a
per-run override does what it looks like it does — and where the two disagree, `pbd` says
which one it used rather than applying it in silence:

```bash
DNS_ZONE=other.com pbd bootstrap ~/src/site
```

Equivalently, export them all in your shell. Required either way:

```bash
export DIGITALOCEAN_ACCESS_TOKEN="dop_v1_..."   # DO API token
export DNSIMPLE_TOKEN="dnsimple_u_..."          # DNSimple API token
export DNSIMPLE_ACCOUNT="12345"                 # DNSimple account id
export DNS_ZONE="example.com"                   # zone the record is created in
export SSH_KEY_NAME="my-key"                    # name of the SSH key in DO
export SSH_PRIVATE_KEY="$HOME/.ssh/id_ed25519"  # path to the matching private key
export SPACES_ACCESS_KEY_ID="..."               # Spaces keypair (Terraform state)
export SPACES_SECRET_ACCESS_KEY="..."
```

Optional (defaults in parentheses):

| Variable | Purpose |
|---|---|
| `FRAMEWORK` | `phoenix` (default), `sinatra` or `zola`. See [Application framework](#application-framework). `sinatra` is SQLite-only; `zola` is a static site with no database. Chosen once per project. |
| `DATABASE_BACKEND` | `sqlite` (default) or `postgres`. See [Database backend](#database-backend). Chosen once per project at first apply; don't flip it on an existing deploy. (`sinatra` forces `sqlite`.) |
| `PROJECT_NAME` | infra naming: DB, VPC, tag (app name). **Immutable after first apply** — renaming would force DB replacement; the script guards this. |
| `REGION` | DO region slug (`nyc3`) |
| `DNS_RECORD` | subdomain inside `DNS_ZONE` (app name); `@` for the apex |
| `ENABLE_STAGING` | `true` — give the app a PR staging environment at `<DNS_RECORD>-stg.<DNS_ZONE>`. `false` provisions none. Always off for a static site. See [Pull-request staging environments](#pull-request-staging-environments) |
| `SSH_CIDRS` | JSON list allowed to SSH, e.g. `["1.2.3.4/32"]` (auto-detected public IP `/32`) |
| `DOCR_REGISTRY` | name if a registry must be created (`PROJECT_NAME`) |
| `STATE_BUCKET` | Spaces bucket for TF state (`<PROJECT_NAME>-tfstate`) — names are globally unique per region; override on collision |
| `SPACES_REGION` | bucket region (`REGION`) — must be a region that offers Spaces |
| `LIVE_TIMEOUT_SECS` | HTTPS liveness poll timeout (`900`) |
| `GIT_PROVIDER` | `github` (default) or `gitea` (self-hosted). See [Gitea support](#gitea-support). |
| `GITEA_URL` | **Gitea only** — base URL of the instance, e.g. `https://git.example.com`. Required. |
| `GITEA_TOKEN` | **Gitea only** — personal access token. Required. |
| `GITEA_OWNER` | **Gitea only** — user/org the repo is created under. Optional: unset, it's whichever account `GITEA_TOKEN` authenticates as. |
| `GITEA_RUNNER_IP` | **Gitea only** — the address the runner's *outbound* traffic comes from, allow-listed once in Terraform. Bare IP or CIDR; comma-separate for more than one. Required. Note this is the runner host's egress IP, **not** a reserved/floating IP attached to it — see [Gitea support](#gitea-support). |

## App types

What gets built is chosen on two axes. **The app type** is the *shape* of the thing — and
therefore what infrastructure it needs. **The language** is what it is written in, within that
shape. A Ruby CLI and a Ruby web app are different things of the same language, which is why
both axes matter.

```bash
pbd bootstrap --cli ruby ~/src/mytool     # or --cli=ruby, or --cli --lang ruby
pbd help bootstrap                      # the full list, rendered from the registry
```

Each `(type, language)` pair also has a **framework** name — `ruby-cli`, `sinatra`, `zola` —
which is what `FRAMEWORK` takes. Framework names are unique across types, so naming one on its
own also picks the type (`FRAMEWORK=zola` still means a service, exactly as before). A bare
language does not: `FRAMEWORK=ruby` is ambiguous and says so.

| | `--service` (default) | `--cli` | `--no-droplet` (alias `--library`) |
|---|---|---|---|
| What it is | a web app served over HTTPS | a command-line program | a reusable package |
| Languages | `elixir`, `ruby`, `static` | `elixir`, `ruby`, `bash`, `typescript` | `elixir` |
| Frameworks | `phoenix`, `sinatra`, `zola` | `escript`, `ruby-cli`, `bash-cli`, `ts-cli` | `mix` |
| Droplet, DNS, TLS | yes | **none** | **none** |
| Database | `postgres` / `sqlite` / none | **none** | **none** |
| Container registry | yes (except `zola`) | **none** | **none** |
| PR staging | yes (except `zola`) | **none** | **none** |
| Credentials needed | DO + DNSimple + Spaces + SSH | **code host only** | **code host only** |
| Local tools | `mix` for Phoenix | `git`, `curl` | `git`, `curl` |
| Pipeline | `.github/workflows/deploy.yml` | `.github/workflows/ci.yml` | `.github/workflows/ci.yml` |
| The bootstrap ends when | `https://<domain>` answers | CI goes green | CI goes green |
| Teardown | droplet, DB, DNS, bucket, registry | nothing exists to destroy | nothing exists to destroy |

The droplet-free types are a genuinely smaller run: eight steps instead of sixteen, no
Terraform, no `doctl`, no SSH, and `preflight` asks for the code host and nothing else. You can
stand up a CLI on a laptop that has never heard of DigitalOcean.

```bash
pbd bootstrap --cli ruby ~/src/mytool
# ==> app: mytool (Mytool) [cli/ruby-cli, ruby] — repo + CI only, no infrastructure
# ==> preparing cli (ruby): CI workflow only (nothing is deployed anywhere)
# ==> CI GREEN: ci.yml passed
# ==> done. cli 'mytool' built and green — no infrastructure was provisioned, so
#     there is nothing to bill and nothing to tear down.
```

`--no-droplet` is a **constraint**, not a type of its own. On its own it builds the default
droplet-free type (a library). Alongside `--cli` it is already satisfied and does nothing.
Against `--service` it fails rather than half-applying — "deploy my Phoenix app without a
server" and "build me a library instead" are different requests, and guessing between them
would hand you an app you didn't ask for.

```
$ pbd bootstrap --no-droplet --service
bootstrap: --no-droplet conflicts with app type 'service' (a web app on its own droplet, ...).
       A 'service' is served from a droplet — there is no droplet-free variant of it.
       Drop the type flag (--no-droplet on its own builds a library), or name a
       droplet-free type: --cli, --library
```

### CLIs: `--cli <language>`

**Every one is a command, not a script.** The thing that makes a CLI worth generating is the
part people skip: real argument parsing. Each scaffold builds on its language's standard option
parser, and each supports the same surface —

```bash
mytool --format json hello there     # not FORMAT=json ./mytool.sh hello there
mytool --format=json hello there     # = also works
mytool -f json                       # short flags
mytool -- --format                   # -- ends the options
mytool --help ; mytool --version     # and exit 0
mytool --nope ; echo $?              # => 2, a usage error, distinct from 1
```

**Every one is a library with a thin executable on top**, which is the other half of the answer:
the work lives in an importable module, and the CLI layer only translates arguments into calls
to it. So the same code is `require "mytool"` / `import { … } from "mytool"` /
`. lib/mytool/core.sh` *and* a command on your PATH — and the tests exercise the library
directly rather than by spawning a process.

| `--cli …` | Parser | Library / entry point | Installs as | CI |
|---|---|---|---|---|
| `elixir` (default) | Elixir `OptionParser` | `lib/<name>.ex` / `lib/<name>/cli.ex` | `mix escript.build` → one file | format, warnings-as-errors, `mix test`, escript built + smoke-tested |
| `ruby` | `OptionParser` (stdlib) | `lib/<name>.rb` / `exe/<name>` | `gem install <name>` | `rspec`, gem built, installed and smoke-tested |
| `bash` | a long/short/`--k=v` loop | `lib/<name>/core.sh` / `bin/<name>` | a symlink on your PATH | `shellcheck -x`, the suite, PATH smoke test |
| `typescript` | `node:util` `parseArgs` | `src/index.ts` / `src/cli.ts` | `npm i -g <name>` | typecheck, `node --test`, package built, installed and smoke-tested |

Two of them have **zero runtime dependencies** (bash needs nothing; TypeScript's parser and test
runner are both stdlib, and `typescript` is the only devDependency). Ruby's parser is stdlib
too. None of the four needs a local toolchain to *scaffold* — like the Sinatra and Zola
scaffolds, they are written by hand in bash and built in CI, so `pbd bootstrap --cli
typescript` works on a machine with no Node installed.

Each pins its toolchain in a file CI reads directly — `.tool-versions`, `.ruby-version`,
`.node-version` — so bumping a runtime is a commit to the project, never an edit to a workflow.
The Elixir pins come from `app/Dockerfile`'s ARGs, so this repo has one place to bump them.

On a tag push (`v*`) the built artifact — escript, `.gem`, npm tarball — is attached to a GitHub
release, so `git tag v1.2.3 && git push --tags` is the whole publish procedure. Pushing to
RubyGems or npm is deliberately *not* automated: that needs a credential the repo doesn't hold,
so the release carries the file and you push it. See [Gitea support](#gitea-support) for what
differs there.

### Libraries: `--no-droplet`

`mix` — an Elixir library: the same project as the escript CLI without the CLI layer, plus
`description`/`package` metadata already stubbed in `mix.exs`, so publishing is a
`mix hex.publish` rather than a rewrite. CI is `mix format --check-formatted` →
`mix compile --warnings-as-errors` → `mix test`.

Gems, hex packages and OTP apps are the next rows here — see below.

### Adding a language or a type

Gems, hex packages and OTP apps belong under `--no-droplet`, and the registry exists so that
adding one is a data change rather than a rewrite. Everything droplet-free in `lib/pbd/bootstrap.sh` is
gated on **capabilities** (`needs_droplet`, `has_database`), never on a type name — so a gem
added later walks the paths a CLI already walks.

[`scripts/app-types.sh`](scripts/app-types.sh) holds two tables. To add a language to a type:

1. Add a row to `APP_STACK_TABLE`: its type, a framework name, its language, the file that
   proves an app already exists there, the scaffold script to run, and the workflow templates
   to copy (`src:dest` pairs).
2. Write the scaffold script under `scripts/`.
3. Add its `ci.<framework>.yml` under `app/.github/workflows/` and `app/.gitea/workflows/`.

That's the whole change — no branch in `lib/pbd/bootstrap.sh` moves. Three of the four CLI languages
were added exactly this way, and the table carries the next three rows commented out as a
worked example:

```
library|gem|ruby|-|<name>.gemspec|new-gem.sh|ci.gem.yml:ci.yml|Ruby gem
library|hex|elixir|-|mix.exs|new-mix-app.sh --hex|ci.hex.yml:ci.yml|Elixir library published to Hex
library|otp|elixir|-|mix.exs|new-mix-app.sh --sup|ci.otp.yml:ci.yml|OTP application (supervision tree)
```

The only place a language is allowed to imply anything beyond its own row is `parse_meta`, which
keys on it to decide where the app's name comes from (`mix.exs`, or the directory, camelized or
not) — a property every stack of one language shares.

A whole new *type* (a different shape, with different infrastructure needs) is a row in
`APP_TYPE_TABLE`: its flag, whether it needs a droplet, whether it may have a database, and
which workflow its pipeline lives in. Its stacks are just the `APP_STACK_TABLE` rows naming it,
and the first of them is its default. The `--<type>` flag is matched against the table too, so
`pbd bootstrap`'s argument parser needs no new case arm either — including for
`--<type> <language>`.

## Application framework

`FRAMEWORK` picks the app stack the bootstrap generates and deploys. Set it once, before the
first `pbd bootstrap`, in your env file or the environment.

| | `phoenix` (default) | `sinatra` | `zola` |
|---|---|---|---|
| Kind | dynamic app | dynamic app | **static site** |
| Language | Elixir | Ruby 3.3+ | Markdown + Tera |
| App | `mix phx.new` (Phoenix 1.8) | `scripts/new-sinatra-app.sh` (modular Sinatra + Sequel) | `scripts/new-zola-site.sh` (themeless starter) |
| Server | `mix release` (OTP) | Puma (Rack) | none — Caddy serves the files |
| Skill docs | `app-template/` | `app-template-ruby/` | `app-template-zola/` |
| Database | `postgres` or `sqlite` | `sqlite` only (forced) | none (forced) |
| Local tools | `mix` (+ `phx_new` archive to generate) | none required — `openssl` for the secret; the Ruby build runs in Docker/CI | none required — the build runs in CI |
| CI gate | `mix test` (Postgres service) | `bundle exec rspec` (SQLite) | `zola build` (a broken template or link fails it) |
| Migrations | release task (`Release.migrate()`) | `rake db:migrate` (Sequel) | n/a |
| Container image | built + pushed to DOCR | built + pushed to DOCR | **none** |
| Release | blue/green swap | blue/green swap | symlink flip |

The two dynamic frameworks share the same infra, TLS, blue/green swap, registry, and rollback
path — only the app-runtime pieces differ (Dockerfile, compose command, CI test/build/migrate,
secret generation). On `sinatra` the bootstrap scaffolds a runnable Sinatra app (an example
`Note` resource with a service object, a Sequel migration, ERB views, and an RSpec suite),
injects the Sinatra skill docs, and wires the Ruby pipeline. Because Sinatra is SQLite-only it
reuses the whole SQLite path below (Litestream replication, no managed Postgres).

An existing app in the target dir is used as-is: a `Gemfile` marks it a Sinatra app, a `mix.exs`
a Phoenix app, a `config.toml` a Zola site. Retrofit an existing Sinatra app's skill docs with
`./scripts/new-sinatra-app.sh <app_dir>`, a Zola site's with `./scripts/new-zola-site.sh <site_dir>`.

### Static sites (`zola`)

`FRAMEWORK=zola` deploys a **static site**, which changes the shape of the deploy rather than
just its language:

```bash
FRAMEWORK=zola pbd bootstrap --host ~/src/myapp ~/src/myblog
```

- **No container, no image, no registry repository.** CI runs `zola build`, tars `public/`, and
  ships it to `/root/apps/<slug>/releases/<sha>` on the droplet. The shared Caddy serves those
  files directly — `/root/apps` is bind-mounted into it at `/srv`.
- **The deploy is one atomic symlink move.** `publish.sh` points `current` at the new release
  with a single `rename(2)`. Caddy resolves the document root per request, so there is no
  reload, no restart and no swap window.
- **Rollback re-points the symlink**: `gh workflow run rollback.yml -f tag=<sha>`. Old releases
  stay on disk (5 by default, `KEEP_RELEASES` in `publish.sh`), so nothing is rebuilt or
  re-uploaded. Past that window, re-deploy the commit instead.
- **No database, no secrets, no `.env` on the droplet.** Nothing a static site ships is secret.
- **`zola build` is the whole CI gate.** A bad template, unparsable front matter or a broken
  internal `@/` link fails the build and nothing is uploaded — the live site keeps serving.
- **Zola is pinned in `.zola-version`**, read by CI. Themes work the standard way (git
  submodules; the checkout is recursive).

Because a static site pushes no image, it is the cheapest thing to put on a droplet that already
serves something else — it consumes a directory and a Caddy site file, and nothing at runtime.
It also sidesteps the container registry entirely, which matters on the free starter tier (one
repository per account).

## Pull-request staging environments

Opening a pull request against `main` stands a **complete copy of the app** up on
the same droplet and serves it at `<app>-stg.<zone>`; closing the PR destroys it.
Pushing to an open PR redeploys it. This is on for every app with a server-side
runtime — Phoenix and Sinatra, host apps and tenants alike. **Static (`zola`)
sites are excluded**: they have no environment to build, only files a symlink
points at.

```
PR opened/pushed   test -> build image (pr-<n>-<sha>) -> migrate -> swap
                   https://myapp-stg.example.com
PR closed/merged   stack + volumes + route destroyed, staging images deleted
```

The environment is a normal app stack in every respect the droplet can see: its
own compose project (`<slug>-stg`), its own volumes, its own container names, its
own site file in the shared Caddy. That is exactly the isolation two *different*
apps on one droplet get — which is the point: a PR cannot reach production's
containers, route or data.

| | production | staging |
|---|---|---|
| Trigger | push to `main` | pull request against `main` |
| Domain | `<record>.<zone>` | `<record>-stg.<zone>` |
| Stack | `/root/apps/<slug>` | `/root/apps/<slug>-stg` |
| Image tag | `<sha>` (+ `:latest`) | `pr-<n>-<sha>`, deleted when the PR closes |
| Data (Postgres) | its own database in the cluster | a **separate database on the same cluster** — no second instance, no extra cost |
| Data (SQLite) | its own volume, replicated to Spaces | its own volume, replicated **into that volume** |
| Signing secret | `SECRET_KEY_BASE` | derived from it in CI — different key, nothing to set |
| Release | health-checked blue/green swap | the same swap, same gate |

Things worth knowing before you rely on it:

- **One staging environment per app, not one per PR.** There is a single staging
  name, so there is a single slot. The most recent PR to deploy holds it,
  recorded in `.staging-owner` on the droplet; a second PR takes the slot over
  (destroying the first PR's environment, data included) and says so in a
  comment. Closing a PR tears the environment down only if that PR still owns it.
- **The DNS record is permanent; the environment is not.** The record is declared
  in Terraform next to the app's own, which is what keeps DNSimple credentials
  out of CI and lets the certificate persist between PRs. Between PRs the name
  resolves to the droplet and nothing serves it.
- **Staging data is scratch, and it never touches production's backups.** On
  SQLite, Litestream replicates into the environment's own volume instead of
  Spaces and the periodic archive is switched off, so the staging deploy carries
  no Spaces keypair at all. On Postgres, staging gets its own database **on the
  app's existing managed cluster** — no second instance is provisioned and the
  bill does not change; only the database name differs from production's, so a
  PR's migrations can never run against production data. That database is **not**
  reset per PR, since dropping it would need a cluster-admin credential in CI.
  Migrations accumulate; when that stops being useful, delete the database in the
  DO console and re-run the bootstrap.
- **Nothing to set per PR — or per app.** Staging's signing key is derived inside
  the deploy job from `SECRET_KEY_BASE` (one-way sha512 under a fixed label), so
  it is stable across deploys, different from production's, and there is no
  second secret to create or rotate. Rotating `SECRET_KEY_BASE` rotates it too.
- **PRs from forks are skipped, deliberately.** This workflow holds the droplet's
  SSH key and the DO API token. GitHub withholds secrets from fork PRs, and
  handing them to unreviewed code would be the wrong fix.
- **The environment shares the droplet's RAM and CPU with production.** Size for
  the sum, as with any second app on the box (see [Several apps on one droplet](#several-apps-on-one-droplet)).
- **Staging images share the app's registry repository** (the free tier allows
  one), tagged `pr-<n>-<sha>`. Superseded tags for a PR are deleted on each
  deploy and the rest when it closes; deleting tags frees manifests, not layers,
  so run `doctl registry garbage-collection start` if the tier's storage gets tight.

Turn it off for an app with `ENABLE_STAGING=false pbd bootstrap <app_dir>`: the
record goes away, the `STAGING_DOMAIN` variable is deleted, and `staging.yml` —
gated on that variable — stops running. An environment that is already up is
*not* torn down by that (the bootstrap never destroys running stacks); do it
explicitly with
`ssh root@<reserved-ip> "APP_SLUG=<slug>-stg bash /root/caddy/staging-down.sh"`.
Apps bootstrapped before this feature existed keep their seeded
`infra/` copy (the bootstrap never overwrites one) and simply get no staging
until they adopt the current `dns.tf`, `database.tf` and `outputs.tf`; the
bootstrap prints the `diff` command that shows what changed.

## Database backend

`DATABASE_BACKEND` picks where the app's data lives. Set it once, before the first
`pbd bootstrap`, in your env file or the environment.

| | `sqlite` (default) | `postgres` |
|---|---|---|
| Where | A SQLite file on the **droplet's local disk** (a named Docker volume) | DigitalOcean Managed Postgres, private-VPC, TLS-verified |
| Backups | **Litestream** streams the WAL to DO Spaces continuously | DO's managed-DB backups |
| Recreate the droplet | a one-shot `litestream restore` on boot pulls the latest replica back | data is untouched (it lives in the managed cluster) |
| Cost | $0 beyond the droplet + a few cents of Spaces storage | + ~$15/mo for the cluster |
| App generation | `mix phx.new --database sqlite3` | `mix phx.new` default (Postgrex) |
| Concurrent writers | one at a time | many |

On `sqlite`, bootstrap provisions **no** managed Postgres (the `database.tf`
resources are gated to zero), skips the TLS-config patch and the schema grant,
and seeds the app repo with Litestream config + the Spaces keypair instead of a
`DATABASE_URL`/CA. The Litestream replica target reuses the Terraform state
bucket under a `litestream/<project>/` prefix — no extra bucket to manage.

Tradeoff you accept on `sqlite`: a single droplet, no read replicas, one writer
at a time, and a small window of un-replicated writes if the droplet dies
between WAL pushes. For the apps this tool builds that's usually fine, and it's
the reason `sqlite` is the default — reach for `postgres` when you actually need
concurrent writers or SQL that SQLite lacks, not by habit.

The flag only affects **newly generated** apps — it does not convert an existing
Postgres app. Because the default is `sqlite`, re-running the bootstrap against
an existing **Postgres** project without setting `DATABASE_BACKEND=postgres`
would ask Terraform to tear that cluster down. The cluster's `prevent_destroy`
would abort the apply, but its database and user carry no such guard and would
be deleted first — so bootstrap detects a cluster in state and **refuses to
apply** instead. Converting a live Postgres app to SQLite is a data migration,
not a flag flip: move the rows through Ecto (both adapters encode their own
types), place the file on the droplet's volume *before* the first SQLite deploy,
and keep the cluster alive until you've verified the new one serves.

## Gitea support

`GIT_PROVIDER` picks the code host **and** the CI/CD engine — GitHub Actions and
Gitea Actions both come from the same choice, since the deploy pipeline is
GitHub-Actions-syntax-compatible either way. Set it once, before the first
`pbd bootstrap`, in your env file or the environment.

| | `github` (default) | `gitea` (self-hosted) |
|---|---|---|
| Repo host | github.com | your instance (`GITEA_URL`) |
| Auth | `gh auth login` | `GITEA_TOKEN` (personal access token) |
| Repo owner | whichever account `gh` is logged in as | whichever account `GITEA_TOKEN` authenticates as, or `GITEA_OWNER` if set (create under an org instead) |
| CI engine | GitHub Actions, GitHub-hosted runners | Gitea Actions, a **self-hosted** runner you register against the instance |
| Workflow files | `.github/workflows/` | `.gitea/workflows/` |
| CI-runner SSH access | temporary `/32` hole punched per deploy (`doctl compute firewall add-rules`/`remove-rules`), because a GitHub-hosted runner's IP is unpredictable | `GITEA_RUNNER_IP` allow-listed **once**, statically, in Terraform (`infra-app/firewall.tf`) — the self-hosted runner has a known IP, so there's nothing to punch or revoke |
| Local tool | `gh` | `curl` (already required) + `jq` |
| Repo/secret/variable API | `gh repo`/`gh secret`/`gh variable` | the instance's REST API directly (`scripts/provider.sh`) |
| Run status | `gh run list --json status,conclusion` | the instance's Actions task-listing API, normalized to the same shape |
| Rollback trigger | `gh workflow run rollback.yml -f tag=...` | the repo's Actions tab, or `POST .../actions/workflows/rollback.yml/dispatches` |
| PR staging environments | on by default (`ENABLE_STAGING`) | **not yet** — see below |
| Repo deletion (`pbd teardown --delete-repo`) | needs the `delete_repo` OAuth scope (`gh auth refresh -s delete_repo`) | needs `GITEA_TOKEN` to carry delete rights on the repo |

Required Gitea-only env: `GITEA_URL`, `GITEA_TOKEN`, `GITEA_RUNNER_IP` (`GITEA_OWNER` is optional — see the table above). All four are documented in `.env.example`.

**`GITEA_RUNNER_IP` is an egress address, and a reserved IP is not one.**
Attaching a DigitalOcean reserved (floating) IP to a droplet
[doesn't replace or change its original public IP](https://docs.digitalocean.com/products/networking/reserved-ips/how-to/outbound-traffic/),
and outbound connections keep using that original address unless you manually
re-point the droplet's default gateway at its anchor IP. So the address Gitea
is *served on* and the address its runner *connects out from* are two different
things, and only the second one belongs in a firewall rule. Get it with:

```bash
ssh root@<your-gitea-host> 'curl -s https://api.ipify.org; echo'
```

`pbd gitea bootstrap` prints the right value (the `gitea_egress_ip` Terraform
output). It **changes when the droplet is replaced**, while the reserved IP
deliberately doesn't — so after a `--replace-droplet`, update `GITEA_RUNNER_IP`
and re-run `pbd bootstrap` for each app to refresh its firewall. The symptom
of a stale value is a deploy job whose `Configure SSH` step takes exactly 5s
(`ssh-keyscan`'s timeout) and then fails on the first `ssh`/`scp`.

**Minimum Gitea version: 1.24.** This is a hard floor, not a recommendation —
it's the first release carrying both Actions API routes bootstrap depends on:

| endpoint | used for | 1.22 | 1.23 | 1.24 |
|---|---|---|---|---|
| `/actions/secrets`, `/actions/variables` | seeding CI config | ✅ | ✅ | ✅ |
| `/actions/tasks` | polling the deploy run to confirm LIVE | ❌ | ✅ | ✅ |
| `/actions/workflows/{id}/dispatches` | redeploying without a new commit | ❌ | ❌ | ✅ |

Secret and variable seeding works on older releases, so a too-old instance
gets most of the way through a bootstrap before failing on a 404 for a route
that was never there. `ci_auth_check` therefore reads `/api/v1/version` during
preflight and stops with the version as the reason. If you provisioned with
`pbd gitea bootstrap`, the pinned tag in `gitea-host/docker-compose.yaml` is
already ≥ 1.24; re-running that script upgrades in place (data is on the
attached volume, and Gitea migrates on start). Take a volume snapshot first if
you're jumping several minor versions at once.

**Why the runner IP is static, not punched.** The GitHub path's hole-punch
exists because GitHub-hosted runners have no fixed IP — a fresh one is
assigned per job. A self-hosted Gitea Actions runner doesn't have that
problem: it's a machine you control, with an IP you already know, so it's
simpler and no less secure to allow-list it once in `infra-app/firewall.tf`
(`gitea_runner_cidr`, wired from `GITEA_RUNNER_IP`) than to reimplement a
punch/revoke dance that exists to solve a problem the Gitea path doesn't have.

**Droplet-free app types work here, minus release uploads.** `--cli` and
`--no-droplet` ship a `.gitea/workflows/ci.yml` for every language, identical
to the GitHub one but for the `gitea.` context — no droplet is involved, so
there is no hole-punch to drop and no DigitalOcean credential to hold. The one
thing missing is the tag-push step that attaches the built escript, `.gem` or
npm tarball to a release: Gitea's runners ship no `gh`, and its release API
wants a token that the automatic per-run token is not guaranteed to carry.
Rather than emit a step that fails on half the instances it lands on, a tag
push builds and keeps the artifact like any other run, and cutting the release
stays manual. Same gap as the staging workflow, and the same fix when someone
wants it.

### Bootstrapping your own Gitea

`GIT_PROVIDER=gitea` needs an actual instance and a registered Actions runner
to talk to. `pbd gitea bootstrap` stands both up, reusing the same
DigitalOcean/DNSimple/Spaces credentials `pbd bootstrap` already needs — one
env file covers both commands.

```bash
pbd gitea bootstrap --check   # verify prerequisites
pbd gitea bootstrap           # provision + configure + start
```

What it does: provisions one dedicated droplet (`infra-gitea/` — its own
Terraform root, applied directly rather than copied into an app repo, since
there's exactly one Gitea instance, not one per app) running Gitea and its
Actions runner **co-located** — simplest and cheapest, and it makes
`GITEA_RUNNER_IP` just that droplet's own egress IP, allow-listed once. Gitea's data
(SQLite DB, git repo objects, Actions logs) lives on a separate persistent
block-storage volume, not the droplet's root disk, so a droplet recreation
(resize, image bump) doesn't lose it — but that volume is **not itself
replicated anywhere** (unlike an app's SQLite file, which Litestream streams
continuously — a multi-file git repo store doesn't fit that model). Snapshot
it yourself for a real backup story.

It also creates the one-time admin account and API token
(`GITEA_ADMIN_EMAIL` is the only new required env var — see the script's
header for the full list of optional ones) and registers the runner. At the
end it prints exactly what to add to your env file for `pbd bootstrap`:

```
GIT_PROVIDER=gitea
GITEA_URL=https://git.example.com
GITEA_TOKEN=...
GITEA_RUNNER_IP=<droplet-egress-ip>/32
```

Idempotent like `pbd bootstrap`: re-running detects what's already done (an
existing admin user, an already-registered runner) rather than redoing it —
important here specifically because Gitea only ever shows a token or the
generated admin password **once**, at creation; the script caches both
locally (`.gitea-admin-token`, `.gitea-admin-password`, gitignored) so a
re-run doesn't need to mint new ones.

`pbd gitea teardown` destroys it — droplet, firewall, reserved IP, DNS
record, and **the data volume** (every repo, the Gitea DB, all of it). It
does not touch any app deployed through the instance, or the state bucket.

**Resizing.** Change `GITEA_DROPLET_SIZE` and re-run. Sizing *up* is an
in-place CPU/RAM resize. Sizing *down* is refused by DigitalOcean — a plan
with a smaller disk gets `This size is not available because it has a
smaller disk`, even with `resize_disk = false`, and snapshots don't help
(a snapshot can only create a droplet with a disk at least as large). Use:

```bash
pbd gitea bootstrap --replace-droplet
```

That recreates the droplet rather than resizing it, which is safe by design
here: the data volume (Gitea's DB and repos, Caddy's certs, the runner's
registration) and the reserved IP are separate resources, and cloud-init
mounts the volume without formatting it. You keep your repos, accounts,
issued certificates, runner registration and IP; only Docker and the pulled
images are rebuilt, which the rest of the run does anyway.

**Verify against your instance before relying on this in production.** Gitea's
Actions API has evolved across releases. `pbd gitea bootstrap` through "Gitea
is answering" (provisioning, Docker, the compose stack) is confirmed against
a live instance — real issues that only showed up there are already fixed:
`infra-gitea/cloud-init.yaml` has to be pure ASCII (an em-dash broke DO's
cloud-init YAML parser and silently discarded the whole config, so Docker
never installed); every `gitea admin`/`gitea actions` CLI call needs
`docker compose exec -u 1000` (exec defaults to root; the gitea binary
refuses to run as root); `gitea-host/docker-compose.yaml` needs
`GITEA__security__INSTALL_LOCK=true` for a headless env-var-driven setup, or
the CLI reports the instance as not-installed no matter what — `/api/healthz`
answering doesn't catch this, since it's a liveness check, not an install
check; that same file must leave `START_SSH_SERVER` off, because the image
already runs sshd on port 22 inside the container and the two racing for it
left Gitea crash-looping; the admin username cannot be `admin`, which
Gitea reserves (the default is now `gitea-admin`, and `--check` rejects a
reserved name up front); and the runner's `GITEA_INSTANCE_URL` must be the
**public** URL rather than a compose-internal one, since job containers run
on the host daemon on their own network and are handed that address as their
clone URL. Past that point — `scripts/provider.sh`'s
`ci_run_row`/`ci_diagnose_dump` (Actions run-status parsing) and
`ci_dispatch_deploy` (workflow dispatch), plus the rest of
`lib/pbd/gitea-bootstrap.sh`'s own `ensure_admin_token`/`ensure_runner` (CLI output
parsing) — is still being verified as issues surface; both fail loud with
the raw output when a parse doesn't match, which is the fastest way to spot
what needs adjusting. A reasonable first run: `pbd gitea bootstrap --check`,
then a full run, then `GIT_PROVIDER=gitea FRAMEWORK=zola pbd bootstrap
--check` against it (smallest surface — no database, no registry) before a
full app bootstrap.

**No PR staging environments yet.** The staging workflow ships as a template
under `app/.github/workflows/` and has no `app/.gitea/workflows/` counterpart,
so a Gitea app has nothing to build a PR environment with. Rather than
provision a staging DNS name and database that no pipeline would ever touch,
`pbd bootstrap` turns the whole feature off on this path (and says so once, if
you asked for it explicitly with `ENABLE_STAGING=true`). Porting the workflow
is the only thing missing — the Terraform, the Caddy routing and
`deploy/staging-down.sh` are all provider-agnostic already.

Everything else — Terraform roots, blue/green swap, database backends, several
apps on one droplet — works identically regardless of `GIT_PROVIDER`.

## Several apps on one droplet

A droplet sized for one small app is usually sized for three. To put a second app
on a droplet that already serves one, name the **host app's directory**:

```bash
pbd bootstrap --host ~/src/myapp ~/src/myotherapp
```

The second app is a **tenant**. It provisions no droplet, no reserved IP, no
firewall, no state bucket and no database — it adds a DNS record pointing at the
host's IP, and on the droplet it gets its own stack directory, compose project,
volumes and Litestream prefix. Its repo carries a single Terraform root
(`infra/tenant/`) whose only resource is that DNS record; the host's state (read
from the shared Spaces bucket) supplies the droplet IP and firewall ID, so a
recreated droplet is picked up on the next apply.

| | host app | tenant app |
|---|---|---|
| Command | `pbd bootstrap <dir>` | `pbd bootstrap --host <host_dir> <dir>` |
| Terraform roots | `infra/{state,persistent,app}` | `infra/tenant` only |
| Owns | droplet, reserved IP, firewall, VPC, state bucket | its DNS record |
| On the droplet | `/root/apps/<slug>` + the shared `/root/caddy` | `/root/apps/<slug>` + one site file |
| Database | `sqlite` or `postgres` | `sqlite` only |
| Teardown | destroys everything, data included | removes its DNS record, its stack and its volumes; leaves the droplet |

Tenants are SQLite-only on purpose: sharing a droplet is a cost decision, and a
per-tenant managed Postgres cluster costs more than the droplet being shared.
(Several apps in *one* cluster — a user, grants and firewall rule per tenant — is
a different feature and isn't built.) Each tenant keeps its own SQLite file on
its own volume with its own Litestream prefix, so tenants can't read each other's
data.

**Migrating an existing droplet.** Droplets bootstrapped before this existed run
a single stack in `/root` with Caddy inside it — a layout that can host exactly
one app. The **host app's next deploy** migrates it: the deploy stops the old
stack, moves the app to `/root/apps/<slug>` (copying its SQLite volume across),
and starts the shared Caddy from `/root/caddy` under the same compose project
name so the issued certificates carry over. That deploy has a short window of
downtime — the only one in this whole tool — from the moment the old stack stops
until the new color passes its healthcheck. Deploy the host app first; a tenant
that arrives before the migration refuses to run rather than adopt the host's
data. The old stack files are parked in `/root/legacy` rather than deleted.

Two things to know when sharing a droplet:

- **Resources are shared, and nothing enforces a split.** A runaway app takes its
  neighbours' RAM and CPU with it. Size the droplet for the sum, and don't put an
  app you can't restart next to one you can't lose.
- **The host's SSH firewall governs everyone.** Port 22 is open only to the CIDRs
  the *host's* `infra/app` was applied with. Bootstrapping a tenant from another
  machine means adding that machine's IP to the host: `SSH_CIDRS='["<host-ip>/32","<your-ip>/32"]' pbd bootstrap <host_dir>`.

## Usage

| Command | Does |
|---|---|
| `pbd check [app_dir]` | verify prerequisites and exit — provisions nothing |
| `pbd bootstrap [app_dir]` | provision, create the repo, wire the pipeline, deploy |
| `pbd teardown [app_dir]` | destroy what bootstrap created, in reverse order |
| `pbd gitea bootstrap` | stand up a self-hosted Gitea + its Actions runner |
| `pbd gitea teardown` | destroy that instance and everything it hosts |
| `pbd config` | where pbd found its templates, its state and your env file |
| `pbd help [command]` | the full options for a command |
| `pbd version` | the version |

`app_dir` defaults to `.`. Every command takes `--help`. A usage error exits **2**; a run
that started and failed exits **1**.

```bash
# 1. Verify everything is in place — exits non-zero naming the FIRST gap:
pbd check ~/src/myapp

# 2. Go:
pbd bootstrap ~/src/myapp

# Or, onto a droplet that already serves ~/src/myapp:
pbd bootstrap --host ~/src/myapp ~/src/myotherapp

# Or build something that isn't a website at all — no droplet, no DNS,
# no database, and no DigitalOcean credentials required. --cli takes the
# language (elixir, ruby, bash, typescript):
pbd bootstrap --cli ruby   ~/src/mytool
pbd bootstrap --no-droplet ~/src/mylib

# The full type + language list:
pbd help bootstrap
```

The steps below describe a **service** — the default. A droplet-free type
([App types](#app-types)) runs eight of them: preflight, generate, parse, repo, prepare (the CI
workflow, and nothing else), seed (nothing to seed), commit + push, and poll until CI concludes.
Steps 4–9 have nothing to do, because nothing was provisioned.

The app name is the directory basename (must be a valid Elixir app name: `lower_snake_case`). What the run does, in order:

1. **Preflight** — same checks as `pbd check`.
2. **Generate** the Phoenix app (`mix phx.new`) if the directory is empty/missing; otherwise use what's there. A non-empty directory without `mix.exs` is refused. Freshly generated apps also get the **Claude skill docs** (`app-template/` → the app's `CLAUDE.md` + `.claude/`, names rewritten) and the deps those docs assume (`req`, `oban` — override with `APP_EXTRA_DEPS`, `""` to skip). Retrofit an existing app with `"$(pbd config | awk '/^root/{print $2}')"/scripts/inject-skill-docs.sh <app_dir>`.
3. **Code host repo** — `git init` if needed, create a private repo (GitHub or Gitea per `GIT_PROVIDER`), and push an `initial commit` of the app as generated. (No workflows exist yet, so this push triggers nothing.)
4. **State bucket** — create the Spaces bucket; both real roots `init` against it (any pre-existing local state migrates in automatically).
5. **Persistent infra** — VPC, reserved IP, managed Postgres (+ its CA cert), DNS record.
6. **Registry** — reuse the account's DO Container Registry or create one (free starter tier).
7. **App infra** — droplet (cloud-init installs Docker only — no secrets), reserved-IP assignment, firewall (22 restricted to your detected IP, 80/443 open).
8. **Wait** until the droplet answers `docker info` over SSH (a responsive daemon, not just the binary).
9. **Grant** the app DB user `CREATE`/`USAGE` on schema `public` (PG15+ default-deny), via the droplet — the only host the DB firewall trusts.
10. **Prepare the app** — deps, `phx.gen.release`, release migration task, *verified* DB TLS config, Dockerfile, compose stack, deploy + rollback workflows.
11. **Seed CI secrets + variables** — secrets (`DIGITALOCEAN_ACCESS_TOKEN`, `SSH_PRIVATE_KEY`, `DATABASE_URL`, `DATABASE_CA_CERT`, fresh `SECRET_KEY_BASE`) and variables (`DOCR_REGISTRY`, `DOMAIN`, `DROPLET_HOST`, `FIREWALL_ID` on the GitHub path only — see [Gitea support](#gitea-support)). On GitHub, unless staging is off, also `STAGING_DOMAIN` (and `STAGING_DATABASE_URL` on Postgres) — that variable is what arms the staging workflow. Staging needs no secret of its own: its signing key is derived in CI.
12. **Commit + push** the pipeline files — which triggers the first deploy through the exact pipeline every later push uses: tests (Postgres service container) → image build → migration gate → blue/green swap.
13. **Poll `https://<domain>`** until live. On failure it prints ordered diagnostics (Actions status, `dig`, Caddy logs) and tells you whether the deploy *failed* or just *isn't ready yet*.

The command is **idempotent**: fix whatever it complained about and re-run; every step detects work already done. (One side effect of re-running: `SECRET_KEY_BASE` is regenerated, which invalidates existing user sessions.)

### Day 2

| Want | Do |
|---|---|
| Deploy | `git push` to `main` (in the app repo) |
| Watch a deploy | `gh run watch` (GitHub) — Gitea: the repo's Actions tab, or `bootstrap:` prints a direct URL on failure |
| Get a staging environment | **GitHub only** — open a PR against `main`; it deploys to `<app>-stg.<zone>` and is destroyed when the PR closes |
| Destroy a staging environment by hand | `ssh root@<reserved-ip> "APP_SLUG=<slug>-stg bash /root/caddy/staging-down.sh"` |
| Roll back | `gh workflow run rollback.yml -f tag=<previous commit sha>` (GitHub) — Gitea: run the `rollback` workflow from the Actions tab (`tag` input), or `POST .../actions/workflows/rollback.yml/dispatches` |
| Change the infrastructure | edit `<app_dir>/infra/…`, commit, `pbd bootstrap <app_dir>` (idempotent, applies all three roots) |
| Recreate the droplet | `terraform -chdir=<app_dir>/infra/app destroy && pbd bootstrap <app_dir>` — DB, IP, DNS, certs survive. **Redeploy every tenant afterwards** (`gh workflow run deploy.yml` in each): their stacks live on that droplet |
| Add another app to the droplet | `pbd bootstrap --host <app_dir> <other_app_dir>` |
| See what's on a droplet | `ssh root@<reserved-ip> 'ls /root/apps && ls /root/caddy/sites'` |
| Verify lifecycle isolation | `scripts/verify-isolation.sh` (asserts a destroy plan touches only droplet/firewall/IP-binding) |
| SSH to the box | `ssh root@<reserved-ip>` (from the IP in `SSH_CIDRS` only) |

For manual Terraform runs, `cd` into the app and export the same env vars plus `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` set to the Spaces keypair (the S3 backend reads those names). `<app_dir>/infra/README.md` documents this for whoever clones the app repo.

## Costs (approximate, monthly)

- Droplet `s-1vcpu-1gb`: ~$6
- Managed Postgres `db-s-1vcpu-1gb`: ~$15
- Spaces subscription: ~$5
- Container registry (starter tier): free — but it allows **one repository**, so a
  second containerized app on the droplet needs the Basic tier (~$5/mo). Static
  (`zola`) sites push no image and use no repository.
- Reserved IP: free while assigned
- Plus your DNSimple subscription.
- **If self-hosting Gitea** (`pbd gitea bootstrap`, optional — GitHub is free
  and needs none of this): droplet `s-1vcpu-1gb` ~$6 + a 40GB data volume ~$4
  + its own reserved IP (free while assigned). No managed Postgres, no
  container registry — Gitea uses SQLite and no image of its own is built.
  Gitea itself is tiny; the droplet size is really a **CI sizing** decision,
  since the co-located runner builds every app you deploy through it —
  `zola` fits the default, `sinatra` wants ~`s-1vcpu-2gb` (~$12), and
  `phoenix` (mix test + a Postgres service container + an Elixir release
  build) wants ~`s-2vcpu-4gb` (~$24). Set `GITEA_DROPLET_SIZE` to bump it.

## Troubleshooting

- **`--check` fails on a tfvars file** — the script injects all Terraform variables via environment; a `terraform.tfvars` would silently override them (Terraform precedence). Move it aside as instructed.
- **`project_name is immutable`** — the requested `PROJECT_NAME` doesn't match existing state. Renaming forces DB-cluster replacement, so the script refuses; keep the old name (it's infra-naming only, independent of the app name).
- **Timeout with "CI still running"** — not a failure; `gh run watch` it. First deploys compile everything from cold cache (~5–10 min).
- **"deploy succeeded but HTTPS not answering"** — usually DNS propagation or first-time Let's Encrypt issuance; the printed `dig` output and Caddy logs localize it.
- **SSH timeouts from your machine** — your public IP changed; re-run the bootstrap (it re-detects) or set `SSH_CIDRS`.

## Teardown

On a **tenant** app, `pbd teardown` removes only that app: its DNS records, its
stack and volumes under `/root/apps/<slug>`, any staging environment left under
`/root/apps/<slug>-stg`, and its routes out of the shared Caddy. The droplet and
its other apps are untouched. (Its Litestream replica in Spaces is left behind —
delete `litestream/<project>/` by hand if you want the data gone.)

A **droplet-free** app has nothing to tear down — it created no bucket, no cluster, no droplet,
no DNS record and no registry repository. `pbd teardown` says so and stops, and demands none of
the DigitalOcean, DNSimple or Spaces credentials the rest of it needs. `--delete-repo` still
deletes the code-host repo; the local directory is never touched either way. (The app records
what it is in `.app-type`; apps created before that file existed are treated as services, which
is what they are.)

```bash
pbd teardown ~/src/mytool                 # "nothing to destroy" — and it means it
pbd teardown --delete-repo ~/src/mytool   # the repo, and only the repo
```

```bash
# Everything, in the right order, with confirmation (data loss!):
pbd teardown <app_dir>

# Or by hand — disposable compute only, data survives:
terraform -chdir=<app_dir>/infra/app destroy

# The DB cluster, reserved IP, and state bucket are protected with
# prevent_destroy; deliberately flip those flags first, then:
terraform -chdir=<app_dir>/infra/persistent destroy
terraform -chdir=<app_dir>/infra/state destroy
```

Also delete the container registry (`doctl registry delete`) and the code-host repo (`pbd teardown --delete-repo`, or by hand) if you're done with them.

## Security notes

- Secrets reach the droplet only over SSH at deploy time (`.env`, mode 600); nothing secret is in cloud-init, droplet metadata, or the image.
- Port 22 is restricted to your CIDR; CI gets a temporary per-run `/32` exception that's revoked even on failure.
- DB: private-VPC only, firewall trusts only the droplet's tag, connections are TLS with full certificate verification against the cluster CA.
- The DO API token is shared with the app repo's Actions secrets (registry + firewall ops). Scope it accordingly, and rotate it if the repo's secret store is ever in doubt.
