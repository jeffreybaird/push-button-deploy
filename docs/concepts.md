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
  to serve, so there is nothing to provision, no credentials to hold and nothing
  to tear down.
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
| `infra/state/` | the DO Spaces bucket that stores the other two roots' state | its own state is local (chicken/egg); losing it is a non-event — `terraform import` re-adopts the bucket |
| `infra/persistent/` | VPC, reserved IP, managed Postgres, DNSimple A records, and a DO *project* grouping the app's resources | must **survive** — `prevent_destroy` everywhere |
| `infra/app/` | droplet, reserved-IP assignment, firewall | **disposable** — `terraform destroy` here never touches data |

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

The separation of roots is the tool's central safety property: **compute is
disposable, data is not.**

- `infra/persistent/` carries `prevent_destroy` on everything that must survive a
  droplet's life — the reserved IP, the database, the DNS records.
- `infra/app/` is the disposable half. `terraform destroy` there tears down the
  droplet and its firewall and touches no data, because the database firewall
  trusts a **tag** the droplet wears, not the droplet's identity. A recreated
  droplet wears the same tag and is trusted again on the next apply, with no
  change to the database.

## Host-owned Caddy and the blue/green swap

The droplet runs an `app_blue`/`app_green` pair, **exactly one live at a time**,
behind Caddy. A deploy:

1. starts the idle color from the new image,
2. waits for its container healthcheck to pass,
3. stops the old color.

Caddy holds and retries requests across the swap window, so the change is
zero-downtime. Migrations run via a release task **before** traffic switches; a
failed migration leaves the old release serving.

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
provisioning data. Port 22 is closed to the world; CI opens a temporary hole for
its own runner IP at the start of a deploy and revokes it afterward. See
[Prerequisites](prerequisites.md) for the credentials involved and
[Operations](operations.md) for the deploy flow.
