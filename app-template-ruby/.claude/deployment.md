# Deployment — Docker + Puma via push-button-deploy

This app deploys through the **push-button-deploy** pipeline: one Ubuntu droplet on
DigitalOcean running Docker Compose, a droplet-wide Caddy terminating TLS, a blue/green pair
of Puma containers, and Litestream replicating the SQLite file to object storage. The droplet
may host other apps too — each gets its own stack directory, compose project and volumes under
`/root/apps/<slug>/`, and adds one site file to the shared Caddy. Every push to `main`
runs the same pipeline. You do not run Kamal, Capistrano, or `docker` by hand.

Related: `.claude/database.md` (the DB file + Litestream), `.claude/testing.md` (the test gate),
`.claude/observability.md` (logs/traces in production).

---

## The mental model

```
git push main
   └─> GitHub Actions (.github/workflows/deploy.yml)
        1. test      — bundle exec rspec              (red tests block everything)
        2. build     — docker build + push to DO Container Registry (SHA-pinned)
        3. deploy    — over SSH to the droplet:
             a. pull the new image
             b. MIGRATE (gate): rake db:migrate as a one-off, BEFORE traffic moves
             c. SWAP: start the idle color, wait for its healthcheck, stop the old color
```

- **The test job is a hard gate.** `build` `needs: test`; a failing spec means nothing ships.
- **Images are immutable and SHA-pinned.** The registry repo is named after the app (read from
  the committed `.app-name` file). `:latest` and `:<git-sha>` are both pushed; deploys pin the SHA.
- **Migrations run before the swap.** `rake db:migrate` runs as a one-off container against the
  live DB volume. If it exits non-zero the job fails and the swap is skipped — the old release
  keeps serving. A bad migration can never serve a half-updated schema. This is why migrations
  must be additive and backward-compatible (see `.claude/database.md`).
- **Zero-downtime swap.** Exactly one of `app_blue`/`app_green` serves at a time. The deploy
  starts the idle color from the new image, waits for its container healthcheck (`up --wait`),
  and only then stops the old one. Caddy holds and retries requests across the window.
- **Rollback is a repin, not a rebuild:** `gh workflow run rollback.yml -f tag=<prior-sha>`.
  It does **not** roll back migrations (additive migrations make that safe); for a schema
  rollback run `rake db:rollback` by hand.

---

## The image (`Dockerfile`)

Multi-stage: a builder installs gems (with the sqlite3 native extension), a slim runtime
carries only what Puma needs plus `libsqlite3`.

- **Ruby version** comes from `.ruby-version` (the `ARG RUBY_VERSION`), the single source of
  truth CI's `ruby/setup-ruby` reads too. Keep the Gemfile's `ruby file: ".ruby-version"` in
  step.
- **Boot command** is `bundle exec puma -C config/puma.rb`. There is no app-name build-arg — a
  Rack app boots by a name-agnostic command, unlike a named OTP release.
- **Runs unprivileged** as uid 65534 (`nobody`), which matches the `chown` the Litestream
  `db_init` sidecar applies to the shared `/data` volume so the app owns the DB file it creates.
- **`.dockerignore`** keeps local SQLite files, `.env`, `spec/`, and dev cruft out of the image.

Don't add secrets to the image. Runtime secrets arrive via `.env` over SSH at deploy time.

---

## The runtime stack (`deploy/compose.yaml`)

On the droplet:

- **`app_blue` / `app_green`** — the Puma app, one live at a time. Both mount the `app_data`
  volume (the SQLite file at `DATABASE_PATH`). Healthcheck: an HTTP probe on `:4000`.
- **`migrate`** — the same image, run as a one-off for the migration gate (`profiles: [tools]`,
  so it never comes up with `up -d`).
- **`db_init`** — one-shot: `litestream restore -if-db-not-exists -if-replica-exists`, then
  `chown` `/data` to the app uid. This is what recovers data on a recreated droplet.
- **`litestream`** — long-running sidecar streaming the WAL to Spaces.

There is **no `caddy` service in this stack.** TLS and routing belong to the droplet's shared
Caddy in `/root/caddy` (only one process can own :443). It terminates TLS with automatic Let's
Encrypt for `DOMAIN` and reverse-proxies to `${APP_SLUG}-blue` / `${APP_SLUG}-green` — the
aliases the two colors publish on the droplet-wide `edge` network.

The app reads its config from environment variables the compose file sets and `.env` supplies —
never from committed config. The variables that matter to your code:

| Var | Meaning |
|---|---|
| `RACK_ENV` | `production` on the droplet |
| `PORT` | `4000` — Puma binds `0.0.0.0:$PORT` |
| `DATABASE_PATH` | on-volume SQLite path (e.g. `/data/my_app.sqlite3`) |
| `SECRET_KEY_BASE` | Rack session secret (`set :sessions, secret:`) |
| `APP_HOST` / `DOMAIN` | the public FQDN, for absolute URLs |
| `APP_SLUG` | this app's name on the droplet — compose project, stack dir, Caddy upstreams |

Litestream/Spaces credentials (`LITESTREAM_*`, `BACKUP_*`) are consumed by the sidecar, not your
app code.

---

## Config & secrets — the rules

- **All config comes from `ENV`.** Use `ENV.fetch("KEY")` (fail fast if required) or
  `ENV.fetch("KEY", default)`. Never read a hardcoded constant that should be runtime config.
- **Locally**, `dotenv` loads `.env` (gitignored) in development/test; copy `.env.example`.
- **In production**, the deploy workflow writes `.env` on the droplet over SSH (mode 600) from
  GitHub Actions secrets/variables. Nothing secret is in the image, cloud-init, or droplet
  metadata.
- **Never commit a real secret.** `.env` is gitignored; `.env.example` holds placeholders only.
- **`SECRET_KEY_BASE`** is generated once by the bootstrap and stored as a repo secret. Rotating
  it invalidates existing sessions.

New secret needed? Add it three places: `.env.example` (placeholder), the compose `environment`
/ `.env` block, and the GitHub secret/variable (the bootstrap seeds these; a new one you add by
hand with `gh secret set`).

---

## Health checks

- The compose healthcheck probes `:4000` over TCP/HTTP; the swap waits on it. Keep the app
  answering quickly on boot — don't block startup on slow warmup.
- A `GET /up` route returns `200` once the process can reach the DB (`DB.test_connection`). Use
  it for external uptime monitoring; keep it cheap and dependency-light.

---

## What you touch vs. what you don't

**You touch:** app code, `db/migrate/`, `Gemfile`, `.ruby-version`, `.env.example`, and specs.
Push to `main`; the pipeline does the rest.

**You (almost) never touch:** `Dockerfile`, `deploy/*.yaml`, `deploy/Caddyfile`,
`deploy/site.caddy.tmpl`, `deploy/edge.sh`, `.github/workflows/*.yml`, `deploy/litestream.yml`. These are managed by the push-button-deploy
tooling. If you change one, understand the blue/green + migration-gate contract first — a broken
healthcheck or a non-additive migration takes the swap down.

---

## Checklist before pushing to `main`

- [ ] `bundle exec rspec` green locally (it's a hard gate in CI)
- [ ] `rubocop` / `bundler-audit` clean
- [ ] Any new migration is additive and safe for the currently-running release
- [ ] New config is in `.env.example` **and** wired into the deploy secrets/vars
- [ ] No secret committed; `ENV.fetch` used for required config
- [ ] `GET /up` still cheap and green
