You're building a push-button deploy pipeline for this Phoenix app: one command provisions DigitalOcean infrastructure, wires a GitHub Actions pipeline, and serves the app over HTTPS. After bootstrap, every push to `main` deploys.

**Work method:** Implement one user story at a time from the backlog (Epics 1–6; Epic 7 is out of scope unless I say otherwise). For each story, satisfy its acceptance criteria, then stop and tell me what to verify before moving on. Don't batch stories. Commit per story with a message naming it.

**Locked decisions — build to these, flag conflicts, don't redesign:**
- Two Terraform root modules with separate state: `infra-persistent/` (VPC, reserved IP, managed Postgres, DNSimple A record) and `infra-app/` (droplet, IP assignment, firewall).
- Compute and data lifecycles are decoupled: `prevent_destroy` + separate state + tag-based DB firewall. Destroying the droplet must never touch the DB or reserved IP.
- DB is DO managed Postgres, private-VPC only. DNS is at DNSimple (`dnsimple` provider, not DO's).
- Runtime is Docker Compose + Caddy on the droplet; Caddy terminates TLS via Let's Encrypt.
- Images live in DO Container Registry, built in CI, pulled on the droplet.
- Provisioning is local and deliberate (`terraform apply`); deploy is per-push (Actions). Never the same workflow.
- No secrets in cloud-init or droplet metadata — registry login and runtime env arrive over SSH at deploy time.
- Everything app-name-agnostic: parse `APP_NAME`/`APP_MODULE` from `mix.exs`; no hardcoded app name in source.

**Non-negotiable correctness requirements:**
- `runtime.exs` must set `ssl: true` for the Repo — DO managed PG rejects non-TLS and Ecto won't infer it from the URL. Fail loudly if absent.
- Migrations run via a release task and must succeed *before* the new container serves traffic; a failed migration fails the deploy and leaves the old container up.
- The DB firewall trusts a tag the droplet wears — assert the tag strings match.

**Don't trust, verify:** This will be run with real credentials I hold; you can't execute it end-to-end. Treat version pins (TF providers, Elixir/OTP base images, marketplace actions) as suspect — check them against this project's actual `mix.exs` and current versions before declaring a story done. Use portable shell (this runs on macOS — BSD `sed`/`awk`).

Start with story 1.1. Before writing anything, confirm your understanding of the architecture and list any assumptions you're making.

**Epic 1 — Persistent infrastructure**

**1.1 — Provision networking and a stable IP**
As a developer, I want a VPC and a reserved IP provisioned via Terraform, so that my app has a private network and an IP that survives droplet recreation.
- `terraform apply` in `infra-persistent/` creates a VPC and a reserved IP.
- Reserved IP has `prevent_destroy = true`.
- `reserved_ip` is a Terraform output.

**1.2 — Provision managed Postgres**
As a developer, I want a DO managed Postgres cluster in the VPC, so that my data lives outside the droplet's lifecycle.
- Cluster is single-node, private-network only, `prevent_destroy = true`.
- A firewall trusts only a named tag — not a droplet ID.
- `database_url` (an `ecto://` string over the private host) is a sensitive output.

**1.3 — Manage DNS at DNSimple**
As a developer, I want an A record for my subdomain pointed at the reserved IP, so that my domain resolves to the app.
- `dnsimple_zone_record` of type A maps `<record>.<zone>` to the reserved IP.
- Record is created in the persistent module (so it predates the droplet).

---

**Epic 2 — App infrastructure**

**2.1 — Provision the app droplet**
As a developer, I want a Docker-ready Ubuntu droplet in the VPC, so that it can run my containers.
- `infra-app/` reads persistent outputs via `terraform_remote_state` (read-only).
- Droplet joins the VPC, carries the trusted tag, and runs cloud-init that installs Docker + compose plugin only (no secrets in metadata).
- Reserved IP is assigned to the droplet.

**2.2 — Lock down the droplet**
As a developer, I want a firewall on the droplet, so that only intended traffic reaches it.
- Port 22 limited to my CIDR; 80/443 open; all egress allowed.
- `ssh root@<ip> docker --version` succeeds after apply.

**2.3 — Guarantee lifecycle isolation**
As a developer, I want destroying the app module to leave the DB and IP intact, so that compute is disposable but data is not.
- `terraform destroy` in `infra-app/` removes the droplet/firewall only.
- DB cluster and reserved IP remain (verified post-destroy).

---

**Epic 3 — App packaging**

**3.1 — Containerize the release**
As a developer, I want a multi-stage Dockerfile producing a `mix release`, so that deploys ship an immutable image.
- Builds with `--build-arg APP_NAME=<app>`; no hardcoded app name.
- `docker build .` yields a runnable image; `CMD` starts the endpoint when `PHX_SERVER=true`.

**3.2 — Enforce DB TLS**
As a developer, I want the Repo configured for SSL, so that connections to managed Postgres aren't rejected.
- `runtime.exs` sets `ssl: true` + `ssl_opts`.
- Tooling fails loudly if this config is absent (TLS is not inferred from the URL).

**3.3 — Provide a migration task**
As a developer, I want a release-callable migrate function, so that schema changes run without Mix in production.
- `lib/<app>/release.ex` exposes `migrate/0` using `Ecto.Migrator`.
- Module name matches the app's actual base module.

---

**Epic 4 — Runtime on the droplet**

**4.1 — Compose the app + reverse proxy**
As a developer, I want a Compose stack with my app and Caddy, so that the droplet serves HTTPS.
- `app` exposes 4000 internally; `caddy` binds 80/443 with persisted cert volumes.
- Image tag is parameterized so deploys can pin a commit SHA.

**4.2 — Automatic TLS**
As a developer, I want Caddy to obtain and renew a Let's Encrypt cert, so that I don't manage certs.
- `Caddyfile` reverse-proxies `$DOMAIN` → `app:4000`.
- First cert issues once the A record resolves (story 1.3 precondition).

---

**Epic 5 — Deploy pipeline**

**5.1 — Build and push on every commit**
As a developer, I want pushes to `main` to build and push an image, so that deploys are automatic.
- Workflow logs into DO Container Registry, builds with the app-name arg, pushes `:<sha>` and `:latest`.
- Concurrency group prevents overlapping deploys.

**5.2 — Deliver and restart over SSH**
As a developer, I want the droplet updated with the new image, so that the new version serves traffic.
- Workflow copies compose + Caddyfile, writes `.env` from secrets, logs in, pulls.
- `docker compose up -d` runs after migrations succeed.

**5.3 — Migrate before traffic**
As a developer, I want migrations to run and gate the restart, so that a bad migration can't serve a half-updated DB.
- `docker compose run --rm app bin/<app> eval "<Module>.Release.migrate()"` runs before `up`.
- A migration failure fails the job; the previous container keeps running.

---

**Epic 6 — Bootstrap**

**6.1 — Verify prerequisites**
As a developer, I want a `--check` mode, so that I catch missing tools/creds before provisioning.
- Checks for required binaries, env vars, SSH key, `gh`/`doctl` auth.
- Exits non-zero naming the first gap.

**6.2 — One-command first run**
As a developer, I want a single script to provision, wire, and deploy, so that standing up a new app is push-button.
- Parses `APP_NAME`/`APP_MODULE` from `mix.exs`.
- Applies both Terraform modules, seeds GitHub secrets/vars, generates `release.ex` if missing.
- Commits + pushes to trigger the first deploy (same path as later deploys).

**6.3 — Confirm liveness**
As a developer, I want the script to poll for HTTPS, so that I know when the app is live.
- Polls `https://<domain>` with a timeout.
- A timeout prints ordered diagnostics (Actions status, `dig`, Caddy logs) and distinguishes "not ready yet" from "deploy failed."

---

**Epic 7 — Operations (post-v1, optional)**

**7.1 — Rollback** — pin a prior image tag without a rebuild.
**7.2 — Zero-downtime** — health-checked swap instead of restart-in-place.
**7.3 — Verified DB TLS** — deliver DO's CA cert, switch to `verify_peer`.
**7.4 — Portable state** — move Terraform state to a DO Spaces backend.