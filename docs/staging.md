# Staging

[← Docs index](index.md) · push-button-deploy

A full copy of the app on every pull request, at `<app>-stg.<zone>`, built when the PR opens and destroyed when it closes — and how to turn it off.

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
containers, route, or data.

## Production vs staging

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

## Before you rely on it

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
  DO console and re-run the bootstrap. See [Databases](databases.md).
- **Nothing to set per PR — or per app.** Staging's signing key is derived inside
  the deploy job from `SECRET_KEY_BASE` (one-way sha512 under a fixed label), so
  it is stable across deploys, different from production's, and there is no second
  secret to create or rotate. Rotating `SECRET_KEY_BASE` rotates it too.
- **PRs from forks are skipped, deliberately.** This workflow holds the droplet's
  SSH key and the DO API token. GitHub withholds secrets from fork PRs, and
  handing them to unreviewed code would be the wrong fix.
- **The environment shares the droplet's RAM and CPU with production.** Size for
  the sum, as with any second app on the box (see [Tenancy](tenancy.md)).
- **Staging images share the app's registry repository** (the free tier allows
  one), tagged `pr-<n>-<sha>`. Superseded tags for a PR are deleted on each
  deploy and the rest when it closes; deleting tags frees manifests, not layers,
  so run `doctl registry garbage-collection start` if the tier's storage gets
  tight.
- **GitHub only, today.** There is no staging workflow for Gitea Actions yet, so
  `ENABLE_STAGING` has no effect under `GIT_PROVIDER=gitea`. See [Gitea](gitea.md).

## Turning it off

Turn it off for an app with:

```bash
ENABLE_STAGING=false ./bootstrap.sh <app_dir>
```

The record goes away, the `STAGING_DOMAIN` variable is deleted, and `staging.yml`
— gated on that variable — stops running.

An environment that is **already up** is *not* torn down by that (the bootstrap
never destroys running stacks). Tear a live one down by hand:

```bash
ssh root@<reserved-ip> "APP_SLUG=<slug>-stg bash /root/caddy/staging-down.sh"
```

Apps bootstrapped before this feature existed keep their seeded `infra/` copy
(the bootstrap never overwrites one) and simply get no staging until they adopt
the current `dns.tf`, `database.tf`, and `outputs.tf`; the bootstrap prints the
`diff` command that shows what changed.
