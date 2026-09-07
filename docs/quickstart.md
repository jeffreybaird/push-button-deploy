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

This runs ~13 steps. You don't drive them — this is what it does, in order, so
you know what you're watching:

1. **Preflight** — the `--check` checks again.
2. **Generate** the Phoenix app with `mix phx.new` (if the directory is
   empty/missing), and inject the [Claude Code docs](claude-docs.md) plus the
   deps they assume. An existing `mix.exs` app is used as-is.
3. **Code host repo** — `git init`, create a private repo (GitHub or Gitea), push
   an initial commit. No workflows exist yet, so this push triggers nothing.
4. **State bucket** — create the DO Spaces bucket that holds Terraform state.
5. **Persistent infra** — VPC, reserved IP, managed Postgres (+ its CA cert), and
   the DNS record. These are the things that must survive (`prevent_destroy`).
6. **Registry** — reuse or create a DO Container Registry.
7. **App infra** — the droplet (cloud-init installs Docker only, no secrets), the
   reserved-IP assignment, and the firewall (22 restricted to your IP, 80/443
   open).
8. **Wait** until the droplet answers `docker info` over SSH.
9. **Grant** the app's DB user `CREATE`/`USAGE` on schema `public`.
10. **Prepare the app** — release config, migration task, verified DB TLS,
    Dockerfile, compose stack, and the deploy + rollback workflows.
11. **Seed CI secrets + variables** — the tokens and config the pipeline needs.
12. **Commit + push the pipeline** — this triggers the **first deploy** through
    the exact pipeline every later push uses: test → build image → migrate →
    health-checked blue/green swap.
13. **Poll `https://<domain>`** until it answers.

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

Verify: the repo exists and its CI run is green. There is nothing to bill and
nothing to tear down.

See [App types](app-types.md) for the full list of types and languages, and
`./bootstrap.sh --help` for everything on one screen.

## Don't remember the flags?

```bash
./bootstrap.sh --interactive        # -i: prompted for every choice, then deploy
```

The interactive walkthrough covers app type, language, code host, and (for a
service) database, staging and tenancy — and can also tailor which
[Claude Code docs](claude-docs.md) the app gets. See [App types](app-types.md).
