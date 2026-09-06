# Databases

[← Docs index](index.md) · push-button-deploy

SQLite (the default, replicated by Litestream) versus managed Postgres — what each costs, how backups work, and why you cannot flip between them on a live app.

`DATABASE_BACKEND` picks where the app's data lives. Set it once, before the
first `./bootstrap.sh`, in `.env` or the environment.

## SQLite vs Postgres

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

## The tradeoff

What you accept on `sqlite`: a single droplet, no read replicas, one writer at a
time, and a small window of un-replicated writes if the droplet dies between WAL
pushes. For the apps this tool builds that is usually fine, and it is the reason
`sqlite` is the default — reach for `postgres` when you actually need concurrent
writers or SQL that SQLite lacks, not by habit.

Framework choice can decide this for you: `sinatra` forces `sqlite`, and `zola`
(a static site) has no database at all. See [Frameworks](frameworks.md).

## The flag only affects newly generated apps

`DATABASE_BACKEND` shapes the app at generation time — it does **not** convert an
existing app.

Because the default is `sqlite`, re-running the bootstrap against an existing
**Postgres** project without setting `DATABASE_BACKEND=postgres` would ask
Terraform to tear that cluster down. The cluster's `prevent_destroy` would abort
the apply, but its database and user carry no such guard and would be deleted
first — so bootstrap detects a cluster in state and **refuses to apply** instead.
The fix is simply to set `DATABASE_BACKEND=postgres` for that project's runs.

Converting a live Postgres app to SQLite is a **data migration**, not a flag
flip:

- move the rows through Ecto (both adapters encode their own types),
- place the file on the droplet's volume *before* the first SQLite deploy, and
- keep the cluster alive until you have verified the new one serves.

## See also

- [Frameworks](frameworks.md) — `sinatra` forces `sqlite`; `zola` has no
  database.
- [Reference](reference.md) — every flag, variable, and cost in one place.
