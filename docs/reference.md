# Reference

[← Docs index](index.md) · push-button-deploy

Commands and their flags, the `scripts/` and `infra-*/` layout, costs and the
security model. For the full environment-variable list see
[Prerequisites](prerequisites.md); for how the pieces fit, [Concepts](concepts.md).

## Commands

### `bootstrap.sh`

Stand up an app, its repo and its pipeline. `app_dir` defaults to `.`.

```bash
./bootstrap.sh [options] [app_dir]
```

| Option | Meaning |
|---|---|
| `--check` | verify prerequisites and exit; provisions nothing |
| `--interactive`, `-i` | prompt step by step for every choice, then deploy |
| `--docs` | guided creation of the app's Claude docs only — provisions nothing (delegates to `claude-docs.sh`) |
| `--host <dir>` | tenant mode: deploy onto the droplet `<dir>`'s app already owns |
| `--lang <language>` | which language, within the app type (also `--cli=ruby`, `--cli ruby`) |
| `--service` / `--cli` / `--library` | pick the app type; each takes its language as `--cli ruby` or `--cli=ruby` |
| `--no-droplet` | build something that provisions no droplet (a library on its own) |
| `--help`, `-h` | usage, rendered from the app-type registry |

Selection can also come from the environment: `APP_TYPE`, `FRAMEWORK`,
`LANGUAGE`. See [App types](app-types.md).

### `claude-docs.sh`

Guided creation of an app's Claude Code docs (`CLAUDE.md` + `.claude/`). Provisions
nothing. `app_dir` defaults to `.`. Full guide: [Claude Code docs](claude-docs.md).

```bash
./claude-docs.sh [options] [app_dir]
```

| Option | Meaning |
|---|---|
| `--framework`, `-f <name>` | `phoenix` / `sinatra` / `zola`; inferred from the marker file when omitted |
| `--all` | include everything without prompting (needs no terminal) |
| `--help`, `-h` | usage |

### `teardown.sh`

Destroy what a bootstrap created. Confirms by having you type the project name.

```bash
./teardown.sh [--yes] [--delete-repo] [app_dir]
```

| Option | Meaning |
|---|---|
| `--yes` | skip the type-the-project-name confirmation |
| `--delete-repo` | also delete the code-host repo (the local directory is never touched) |

See [Operations](operations.md) for the teardown walkthrough and the manual
`terraform destroy` order.

### `bootstrap-gitea.sh` / `teardown-gitea.sh`

Stand up (or destroy) a self-hosted Gitea instance + its Actions runner. Full
guide: [Gitea](gitea.md).

```bash
./bootstrap-gitea.sh [--check] [--replace-droplet]
./teardown-gitea.sh
```

| Option | Meaning |
|---|---|
| `--check` | verify prerequisites and exit |
| `--replace-droplet` | recreate the droplet instead of resizing (keeps the data volume, IP, certs, runner registration) |

## `scripts/`

| Script | Role |
|---|---|
| `app-types.sh` | the app-type × framework registry (sourced) |
| `app-meta.sh` | parse `APP_NAME` / `APP_MODULE` from `mix.exs` (sourced + runnable) |
| `provider.sh` | code-host + CI abstraction (GitHub vs Gitea) (sourced) |
| `tfstate.sh` | Spaces state-bucket bootstrap, shared by both bootstrap scripts (sourced) |
| `prompt.sh` | interactive prompt primitives (sourced) |
| `claude-docs.sh` | the shared Claude-docs injector (sourced + runnable) |
| `inject-skill-docs.sh` | Phoenix: inject deps + Claude docs (runnable) |
| `new-sinatra-app.sh` / `new-zola-site.sh` | scaffold + inject docs for those frameworks |
| `new-mix-app.sh` / `new-ruby-cli.sh` / `new-bash-cli.sh` / `new-ts-cli.sh` | CLI / library scaffolds |
| `sync-infra.sh` | re-seed an app's `infra/` from the templates |
| `ensure-db-tls.sh` / `ensure-release-task.sh` | Phoenix release prep helpers |
| `verify-isolation.sh` | assert a destroy plan touches only disposable compute |

## Terraform roots

The `infra-*/` directories here are **templates**; the bootstrap copies them into
`<app_dir>/infra/{state,persistent,app}` (or `infra/tenant` for a tenant) and runs
Terraform from there, so an app's infrastructure is versioned alongside its code.

| Root | Owns | Lifecycle |
|---|---|---|
| `infra-state` | the Spaces bucket that stores the other roots' state | its own state is local (chicken/egg) |
| `infra-persistent` | VPC, reserved IP, managed Postgres, DNS records, the DO project | must survive — `prevent_destroy` |
| `infra-app` | droplet, reserved-IP assignment, firewall | disposable — destroy never touches data |
| `infra-tenant` | a tenant's single DNS record | reads the host's state for IP/firewall |
| `infra-gitea` | the self-hosted Gitea host (its own combined root) | applied directly, not per-app |

For manual Terraform runs, `cd` into the app and export the same env vars plus
`AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` set to the Spaces keypair (the S3
backend reads those names). Each app's `infra/README.md` documents this.

## Costs (approximate, monthly)

| Item | Cost |
|---|---|
| Droplet `s-1vcpu-1gb` | ~$6 |
| Managed Postgres `db-s-1vcpu-1gb` | ~$15 (SQLite apps: $0) |
| Spaces subscription | ~$5 |
| Container registry (starter tier) | free — one repository; a second containerized app needs Basic (~$5) |
| Reserved IP | free while assigned |
| DNSimple | your subscription |
| Self-hosted Gitea (optional) | droplet ~$6 + 40GB volume ~$4; sized for CI load |

Static (`zola`) sites push no image and use no registry repository — the cheapest
thing to add to an existing droplet. See [Databases](databases.md) for the
SQLite-vs-Postgres cost tradeoff.

## Security model

- Secrets reach the droplet only over SSH at deploy time (`.env`, mode 600).
  Nothing secret is in cloud-init, droplet metadata, or the image.
- Port 22 is restricted to your CIDR; on GitHub, CI gets a temporary per-run
  `/32` exception that's revoked even on failure. On Gitea the runner's IP is
  allow-listed once (see [Gitea](gitea.md)).
- The database is private-VPC only; its firewall trusts the droplet's **tag**,
  not its ID; connections are TLS with full certificate verification against the
  cluster CA.
- The DO API token is shared with the app repo's Actions secrets (registry +
  firewall ops). Scope it accordingly and rotate it if the repo's secret store is
  ever in doubt.
