# Quickstart

[← Docs index](index.md) · push-button-deploy

A worked example: one web service, from an empty directory to live HTTPS, with a
CI/CD pipeline that redeploys every push to `main`. Then a shorter droplet-free
quickstart for a CLI.

Before you start, work through [Prerequisites](prerequisites.md) — the tools,
accounts and `.env`. This page assumes they're in place.

## Service: empty directory → live HTTPS

We'll build a Phoenix app called `myapp` (the default framework). The app name is
the directory basename and must be a valid Elixir app name (`lower_snake_case`).

### 1. Verify your setup

Goal: catch a missing tool or credential before anything is provisioned.

```bash
./bootstrap.sh --check ~/src/myapp
```

What happens: the same preflight the real run does, but it provisions nothing and
exits non-zero naming the **first** gap it finds. Fix it and re-run until it's
clean.

Verify: exit status 0 and no complaint printed.

### 2. Go

Goal: provision everything and deploy.

```bash
./bootstrap.sh ~/src/myapp
```

The default host run has 16 progress steps (a tenant has 14). In order:

1. **Preflight** — the `--check` checks again.
2. **Generate** the Phoenix app with `mix phx.new` (if the directory is
   empty/missing), with SQLite by default, and install [agent docs](claude-docs.md)
   plus the injected development dependencies. Existing apps skip generation.
3. **Identity** — read app/module names and derive infrastructure names.
4. **Code host repo** — initialize Git if needed, create/reuse a private repo,
   and push the app. Fresh scaffolds have no deployment workflow yet; existing
   repositories may already have workflows that run on this push.
5. **Terraform templates** — seed the app's `infra/` roots without overwriting them.
6. **State bucket** — create/reuse the DO Spaces bucket holding Terraform state.
7. **Persistent infra** — VPC, reserved IP and DNS; managed Postgres and its CA
   only when `DATABASE_BACKEND=postgres`. SQLite backups use the Spaces bucket.
8. **Registry** — reuse or create a DO Container Registry.
9. **SSH access** — resolve your allowed CIDR.
10. **App infra** — the droplet (cloud-init installs Docker only, no secrets), the
   reserved-IP assignment, and the firewall (22 restricted to your IP, 80/443
   open).
11. **Wait** until the droplet answers `docker info` over SSH.
12. **Grant** schema privileges for Postgres; skip this on SQLite.
13. **Prepare the app** — release/migration files, Dockerfile, compose stack,
    workflow files, and agent-doc adoption if needed. Verified DB TLS is Postgres-only.
14. **Seed CI secrets + variables** — the tokens and config the pipeline needs.
15. **Commit + push the pipeline** — this triggers a fresh app's **first deploy** through
    the exact pipeline every later push uses: test → build image → migrate →
    health-checked blue/green swap.
16. **Confirm the exact commit's workflow succeeds**, then poll HTTPS. Each wait
    has its own `LIVE_TIMEOUT_SECS` budget (900 seconds by default).

What happens at the end:

```
==> LIVE: https://myapp.example.com
```

Verify: open the URL, or `curl -I https://myapp.example.com`. If it times out,
the script prints ordered diagnostics (Actions status, `dig`, Caddy logs) and
tells you whether the deploy **failed** or just **isn't ready yet** — see
[Troubleshooting](troubleshooting.md).

> The run is **idempotent**. If a step fails, fix what it named and run the exact
> same command again — every step detects work already done.

Bootstrap stages all app changes when it commits the pipeline. Commit or set
aside unrelated work first. Deployment files are refreshed on reruns; existing
Terraform roots and already-managed agent docs follow their separate ownership
rules. See [Operations](operations.md).

### 3. Deploy a change

Goal: ship an edit.

```bash
cd ~/src/myapp
# edit code...
git commit -am "change something"
git push
```

What happens: the push to `main` runs the pipeline — tests gate the build, the
image is built and pushed, migrations run before traffic switches, then a
health-checked blue/green swap. Zero downtime.

Verify: `gh run watch` (GitHub) or the repo's Actions tab (Gitea).

Next: [Operations](operations.md) for rollback, staging, recreating the droplet
and teardown.

## Droplet-free: a CLI in one command

Not everything is a website. `--cli` builds a real command-line program — repo
and CI only, no droplet, no DNS, no database, and **none** of the
DigitalOcean/DNSimple/Spaces credentials.

```bash
./bootstrap.sh --cli ruby ~/src/mytool     # also: elixir, bash, typescript
```

What happens: eight steps instead of sixteen — preflight (asks for the code host
and nothing else), generate the scaffold, create the repo, add a CI workflow,
commit, push, and poll until CI is green.

```
==> CI GREEN: ci.yml passed
==> done. cli 'mytool' built and green — no infrastructure was provisioned.
```

Verify: the repo exists and its CI run is green. No cloud infrastructure is
provisioned; code-host and CI usage may still have costs. The remote repository
can be removed with `teardown.sh --delete-repo` if no longer needed.

See [App types](app-types.md) for the full list of types and languages, and
`./bootstrap.sh --help` for everything on one screen.

## Don't remember the flags?

```bash
./bootstrap.sh --interactive        # -i: prompted for every choice, then deploy
```

The interactive walkthrough covers app type, language, code host, and (for a
service) database, staging and tenancy — and can also tailor which
[agent docs](claude-docs.md) the app gets. See [App types](app-types.md).
