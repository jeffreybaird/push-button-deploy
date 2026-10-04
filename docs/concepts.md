# Concepts

[← Docs index](index.md) · push-button-deploy

The mental model behind the tool: how an app is described, where its
infrastructure lives, and what keeps a deploy safe.

## Two axes: app type × framework

What gets built is chosen on **two axes**, and both matter because a Ruby CLI and
a Ruby web app are different things written in the same language.

- **App type** — the *shape* of the thing, and therefore what infrastructure it
  needs. A `service` is a long-running web app: it wants a droplet, DNS, TLS and
  maybe a database. A `cli` or a `library` needs none of that — there is nothing
  to serve, so there is no cloud infrastructure to provision. Code-host
  authentication and optional remote-repository deletion still apply.
- **Framework** — the *stack* inside that shape: which scaffold generates the
  app, which file proves one already exists, and which CI workflows it gets. Each
  framework belongs to exactly one type.

The split is what makes the tool extensible. Every step the bootstrap skips for a
droplet-free app is gated on a **capability** the type declares (`needs_droplet`,
`has_database`), never on a type name — so a stack added later walks the same
paths an existing one already walks.

See [App types](app-types.md) for the three types and how to select one, and
[Frameworks](frameworks.md) for the service stacks in detail.

### The registry

Both axes come from one file, [`scripts/app-types.sh`](../scripts/app-types.sh),
which holds two tables:

| Table | One row per | Says |
|---|---|---|
| `APP_TYPE_TABLE` | app type | its flag, whether it needs a droplet, whether it may have a database, which workflow carries its pipeline |
| `APP_STACK_TABLE` | (type, framework) pair | its language, the file that proves an app already exists, the scaffold script, and the CI workflow templates to copy |

A type's stacks are simply the stack-table rows that name it, and the first of
them is that type's default. The current registry:

| Type | Frameworks |
|---|---|
| `service` | `phoenix` (Elixir), `sinatra` (Ruby), `zola` (static) |
| `cli` | `escript` (Elixir), `ruby-cli` (Ruby), `bash-cli` (bash), `ts-cli` (TypeScript) |
| `library` | `mix` (Elixir) |

Framework names are unique across the whole table, which is what lets naming one
alone also pick the type: `FRAMEWORK=zola` still means "a service". A bare
language does not — `ruby` builds a Sinatra service *and* a gem-layout CLI, so it
cannot identify a type on its own, and the tool says so rather than guessing.

## The Terraform roots

A service's infrastructure is split across **three Terraform roots with
deliberately separate state**, so each can change or be destroyed without
touching the others:

| Root | Holds | Lifecycle |
|---|---|---|
| `infra/state/` | the DO Spaces bucket holding other roots' state and SQLite backups | local state; the bucket has `prevent_destroy` and can be re-imported if local state is lost |
| `infra/persistent/` | VPC, reserved IP, optional managed Postgres, DNS and DO project | separate state; only reserved IP and DB cluster have `prevent_destroy` here |
| `infra/app/` | droplet, reserved-IP assignment, firewall | destroying it leaves persistent-root resources intact but deletes the droplet's local disk |

A **tenant** app (one deployed onto a droplet another app owns) has a fourth,
much smaller root instead of these three — `infra/tenant/`, holding only its DNS
record. See [Tenancy](tenancy.md).

The roots live **in the app repo**, not here. The `infra-*/` directories in this
repo are templates; the bootstrap copies them into
`<app_dir>/infra/{state,persistent,app}` and runs Terraform from there, so an
app's infrastructure is versioned, reviewed and rolled back alongside the code
that runs on it. The copy is seeded once and never overwritten, so local edits
survive re-runs.

## Compute and data are isolated

Separate state keeps an app-root destroy from deleting the managed Postgres
cluster, reserved IP, or DNS. The database firewall trusts a **tag**, so a
replacement droplet can reconnect without replacing the cluster.

Local disk is different: SQLite volumes, static releases, and Caddy certificate
volumes are on the app droplet. SQLite recovers from the latest available
Litestream replica in Spaces, potentially losing unreplicated writes. Static
sites must be redeployed, and Caddy obtains certificates again. Verify backups
before replacement; see [Operations](operations.md#recreate-the-droplet).

## Host-owned Caddy and the blue/green swap

The droplet uses an `app_blue`/`app_green` pair behind Caddy. One remains running
after a successful deploy; both can run during the transition. A deploy:

1. starts the idle color from the new image,
2. waits for its container healthcheck to pass,
3. stops the old color.

Caddy lists both upstreams and retries failed connections. The script waits for
the new container's healthcheck before stopping the old one; it does not perform
an exclusive route switch or guarantee uninterrupted long-lived connections.
Migrations run first; a failure prevents the swap, but cannot undo database
changes already applied. Use backward-compatible migrations.

Caddy is **host-owned, not app-owned**: one instance per droplet, in
`/root/caddy`, importing one site file per app. Each app's stack lives in
`/root/apps/<slug>/` as its own compose project with its own volumes, and the two
colors publish `<slug>-blue` / `<slug>-green` aliases on a shared `edge` network
for Caddy to dial. That is what makes a second app on the same droplet possible;
with one app it is the same machinery with a single site file. (A static Zola
site has no container to swap — it releases with a symlink flip instead. See
[Frameworks](frameworks.md).)

## Secrets arrive at deploy time

Secrets are **never** written into cloud-init or droplet metadata. They arrive
over SSH at deploy time, so nothing sensitive is recoverable from the droplet's
provisioning data. SSH is restricted to configured CIDRs. GitHub CI opens a
temporary runner-IP exception and revokes it afterwards; Gitea uses configured
static runner CIDRs. See
[Prerequisites](prerequisites.md) for the credentials involved and
[Operations](operations.md) for the deploy flow.
