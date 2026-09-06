# Prerequisites

[← Docs index](index.md) · push-button-deploy

Everything you install and set before the first `./bootstrap.sh` — tools, accounts, credentials, and the full `.env` reference — plus how `--check` verifies it.

## Tools

These are what a **service** (the default app type) needs. `--check` verifies
every one and exits naming the first that is missing.

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

### Droplet-free runs need far less

The table above is for a service. The droplet-free types — `--cli` and
`--no-droplet` (see [App types](app-types.md)) — provision no infrastructure, so
they need only `git`, `curl`, and the code host's tool (`gh`, or `jq` for
Gitea): no Terraform, no `doctl`, no SSH, and **no local runtime of the language
you pick**. Every scaffold is written in bash and built in CI, so
`./bootstrap.sh --cli typescript` works on a machine with no Node installed. The
credentials below are likewise service-only — a droplet-free run needs none of
them.

## Accounts and credentials

One-time setup, needed only for a **service**.

1. **DigitalOcean**
   - An API token with write access: *API → Tokens → Generate New Token*.
   - A **Spaces keypair** (separate from the API token): *API → Spaces Keys*.
     Spaces requires the ~$5/mo Spaces subscription, which activates with the
     first bucket.
   - An SSH key uploaded to the account (*Settings → Security*) — note its
     **name**.
   - `doctl auth init` (paste the API token).
2. **DNSimple**
   - A zone (domain) hosted there, an API token, and your numeric account ID
     (visible in the URL or account page).
3. **Code hosting + CI/CD** — `GIT_PROVIDER` picks which (default `github`; see
   [Gitea](gitea.md) for the other).
   - **GitHub** (default): `gh auth login` with permission to create repos and
     set secrets/variables.
   - **Gitea** (self-hosted, `GIT_PROVIDER=gitea`): a personal access token with
     repo create/delete and Actions secrets/variables scopes, and — because it
     also runs the pipeline (Gitea Actions) — a self-hosted runner registered
     against the instance, with a stable IP you can name in `GITEA_RUNNER_IP`.

## Environment variables

The easiest way: copy `.env.example` to `.env` next to `bootstrap.sh` and fill
it in. The script sources it automatically (values in the file override the
calling shell). It is gitignored; still, `chmod 600 .env`.

```bash
cp .env.example .env && chmod 600 .env
$EDITOR .env
```

Equivalently, export them in your shell.

### Required (service only)

None of these are needed for a droplet-free (`--cli`, `--no-droplet`) run.

| Variable | Required? | Purpose |
|---|---|---|
| `DIGITALOCEAN_ACCESS_TOKEN` | yes (service) | DO API token with write access |
| `DNSIMPLE_TOKEN` | yes (service) | DNSimple API token |
| `DNSIMPLE_ACCOUNT` | yes (service) | DNSimple numeric account id |
| `DNS_ZONE` | yes (service) | zone the DNS record is created in |
| `SSH_KEY_NAME` | yes (service) | name of the SSH key in DO |
| `SSH_PRIVATE_KEY` | yes (service) | path to the matching private key |
| `SPACES_ACCESS_KEY_ID` | yes (service) | Spaces keypair (Terraform state bucket) |
| `SPACES_SECRET_ACCESS_KEY` | yes (service) | Spaces keypair secret |

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

### Optional (defaults shown)

| Variable | Required? | Purpose |
|---|---|---|
| `FRAMEWORK` | no | `phoenix` (default), `sinatra` or `zola`. Names the stack — and, being unique across app types, also picks the type. `sinatra` is SQLite-only; `zola` is a static site with no database. Chosen once per project. See [Frameworks](frameworks.md). |
| `LANGUAGE` | no | The language within the app type: service `elixir` (default) / `ruby` / `static`; cli `elixir` (default) / `ruby` / `bash` / `typescript`; library `elixir`. Same choice as `--lang`. |
| `APP_TYPE` | no | `service` (default), `cli`, or `library`. `cli`/`library` provision nothing; better passed per-run as `--cli` / `--no-droplet`. See [App types](app-types.md). |
| `DATABASE_BACKEND` | no | `sqlite` (default) or `postgres`. Chosen once at first apply; don't flip it. `sinatra` forces `sqlite`. See [Databases](databases.md). |
| `PROJECT_NAME` | no | Infra naming (DB, VPC, tag). **Immutable after first apply** — the script guards it. |
| `REGION` | no | DO region slug (`nyc3`). |
| `DNS_RECORD` | no | Subdomain inside `DNS_ZONE` (app name); `@` for the apex. |
| `ENABLE_STAGING` | no | `true` (default) gives the app a PR staging environment at `<DNS_RECORD>-stg.<DNS_ZONE>`; `false` provisions none. Always off for a static site, and not yet for Gitea. See [Staging](staging.md). |
| `SSH_CIDRS` | no | JSON list allowed to SSH, e.g. `["1.2.3.4/32"]` (defaults to auto-detected public IP `/32`). |
| `HOST_APP_DIR` | no | Tenant mode: deploy onto the droplet this other app owns instead of provisioning one. Same as `--host`. SQLite or static only. See [Tenancy](tenancy.md). |
| `DOCR_REGISTRY` | no | Registry name if one must be created (`PROJECT_NAME`). |
| `STATE_BUCKET` | no | Spaces bucket for TF state (`<PROJECT_NAME>-tfstate`) — globally unique per region; override on collision. |
| `SPACES_REGION` | no | Bucket region (`REGION`) — must be a region that offers Spaces. |
| `LIVE_TIMEOUT_SECS` | no | HTTPS liveness poll timeout (`900`). |
| `GIT_PROVIDER` | no | `github` (default) or `gitea` (self-hosted). See [Gitea](gitea.md). |
| `GITEA_URL` | Gitea only | Base URL of the instance, e.g. `https://git.example.com`. |
| `GITEA_TOKEN` | Gitea only | Personal access token (repo create/delete, Actions secrets/vars). |
| `GITEA_OWNER` | no | User/org the repo is created under. Unset, it is whichever account `GITEA_TOKEN` authenticates as. |
| `GITEA_RUNNER_IP` | Gitea only | The runner's **egress** IP/CIDR, allow-listed once in Terraform. Comma-separate for more than one. Not a reserved/floating IP — see [Gitea](gitea.md). |

The `GITEA_*` block above configures Gitea as a code host. A separate set of
`GITEA_*` variables belongs to `bootstrap-gitea.sh`, which provisions the Gitea
instance itself — see [Gitea](gitea.md).

## Verify with `--check`

Before the first real run, dry-check the environment:

```bash
./bootstrap.sh --check [app_dir]
```

It inspects the tools, credentials, and variables that the run you describe
actually needs, then exits **naming the first gap** — a missing tool, an unset
required variable, an absent credential — so you fix them one at a time. Pass the
same flags you intend to use (`--cli`, `--no-droplet`, `GIT_PROVIDER=gitea`,
and so on): `--check` scopes its checks to that run, so a droplet-free check does
not demand the DigitalOcean, DNSimple, or Spaces credentials. A clean `--check`
means the real bootstrap has what it needs to start.

Next: the [Quickstart](quickstart.md) walks a service from empty directory to
live HTTPS.
