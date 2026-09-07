# Tenancy

[← Docs index](index.md) · push-button-deploy

Put several apps on one droplet — one **host** that owns the infrastructure, and
**tenants** that ride along on it.

A droplet sized for one small app is usually sized for three. Rather than stand
up a droplet, reserved IP, firewall and state bucket per app, you point a new
app at a droplet you already have. It becomes a tenant: it adds only a DNS
record and its own stack, and shares everything else.

## The command

To put a second app on a droplet that already serves one, name the **host app's
directory**:

```bash
./bootstrap.sh --host ~/src/myapp ~/src/myotherapp
```

`~/src/myapp` is the host (already deployed); `~/src/myotherapp` is the new
tenant. The host is bootstrapped the ordinary way — `./bootstrap.sh <dir>`, with
no `--host`.

## Host app vs tenant app

The host owns the droplet and all the shared, stateful infrastructure. A tenant
provisions no droplet, no reserved IP, no firewall, no VPC, no state bucket and
no database. It adds a DNS record pointing at the host's IP, and on the droplet
it gets its own stack directory, compose project, volumes and Litestream prefix.

A tenant's repo carries a single Terraform root, `infra/tenant/`, whose only
resource is that DNS record. The host's state — read from the shared Spaces
bucket — supplies the droplet IP and firewall ID, so a recreated droplet is
picked up on the tenant's next apply.

| | host app | tenant app |
|---|---|---|
| Command | `./bootstrap.sh <dir>` | `./bootstrap.sh --host <host_dir> <dir>` |
| Terraform roots | `infra/{state,persistent,app}` | `infra/tenant` only |
| Owns | droplet, reserved IP, firewall, VPC, state bucket, database | its DNS record |
| On the droplet | `/root/apps/<slug>` + the shared `/root/caddy` | `/root/apps/<slug>` + one site file |
| Database | `sqlite` or `postgres` | `sqlite` only |
| Teardown | destroys everything, data included | removes its DNS record, its stack and its volumes; leaves the droplet |

## Why tenants are SQLite-only

Sharing a droplet is a cost decision, and a per-tenant managed Postgres cluster
costs more than the droplet being shared — so a Postgres tenant would defeat the
point. (Several apps in *one* cluster — a user, grants and firewall rule per
tenant — is a different feature, and isn't built.)

Each tenant keeps its own SQLite file on its own volume with its own Litestream
prefix, so tenants can't read each other's data. See [Databases](databases.md)
for how SQLite and Litestream work.

## Migrating an existing droplet

Droplets bootstrapped before tenancy existed run a single stack in `/root` with
Caddy inside it — a layout that can host exactly one app. The **host app's next
deploy** migrates it automatically:

- it stops the old stack,
- moves the app to `/root/apps/<slug>`, copying its SQLite volume across,
- and starts the shared Caddy from `/root/caddy` under the same compose project
  name, so the issued certificates carry over.

That deploy has a short window of downtime — the only one in this whole tool —
from the moment the old stack stops until the new color passes its healthcheck.
The old stack files are parked in `/root/legacy` rather than deleted.

Deploy the host app first. A tenant that arrives before the migration refuses to
run rather than adopt the host's data.

## Two cautions when sharing a droplet

- **Resources are shared, and nothing enforces a split.** A runaway app takes
  its neighbours' RAM and CPU with it. Size the droplet for the sum, and don't
  put an app you can't restart next to one you can't lose.
- **The host's SSH firewall governs everyone.** Port 22 is open only to the
  CIDRs the *host's* `infra/app` was applied with. Bootstrapping a tenant from
  another machine means adding that machine's IP to the host:

  ```bash
  SSH_CIDRS='["<host-ip>/32","<your-ip>/32"]' ./bootstrap.sh <host_dir>
  ```

## See also

- [Databases](databases.md) — SQLite/Litestream, and why tenants use it
- [Concepts](concepts.md) — the Terraform roots and the droplet layout
- [Operations](operations.md) — adding an app, recreating a droplet, teardown
