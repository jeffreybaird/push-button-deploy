# Operations

[← Docs index](index.md) · push-button-deploy

Day-2 how-tos: deploy a change, watch it, roll back, change infrastructure,
recreate the droplet, add an app, look inside, and tear down.

Each task states its **goal**, the **commands**, **what happens**, and how to
**verify**. Commands run from the repo root; `<app_dir>`, `<slug>`, `<domain>`
and the like are placeholders you replace. Where GitHub and Gitea differ, both
are shown — see [Gitea](gitea.md).

## Deploy a change

**Goal:** ship a code change to the live app.

```bash
# in the app repo
git push               # to main
```

**What happens:** the push to `main` triggers the deploy pipeline every later
push uses — tests, image build, migration gate, blue/green swap. The old color
is stopped only after the new one passes its healthcheck; Caddy lists both
upstreams during the transition. Zola instead builds and publishes a directory;
CLI/library apps run build/test CI without a deployment.

**Verify:** watch the run (below), or hit `https://<domain>` once it concludes.

## Watch a deploy

**Goal:** follow a running deploy and see its result.

```bash
gh run watch                                   # GitHub
```

On **Gitea**, open the repo's **Actions** tab. `bootstrap:` also prints a direct
run URL on failure.

**What happens:** you see each job — tests, build, migration gate, swap — as it
runs.

**Verify:** the run concludes green; `https://<domain>` serves the change.

## Roll back

**Goal:** put a previous build back in service.

```bash
gh workflow run rollback.yml -f tag=<previous-sha>   # GitHub, from the app repo
```

On **Gitea**, run the `rollback` workflow from the repo's Actions tab (with the
`tag` input), or dispatch it over the API:

```bash
POST .../actions/workflows/rollback.yml/dispatches
```

**What happens:** the pipeline redeploys the image built for `<tag>` and swaps
it into service — same blue/green swap as a forward deploy, no rebuild or
migration reversal. The prior image must still exist and support the current
schema. Zola rollback selects a release directory still retained on the droplet.

**Verify:** `https://<domain>` serves the rolled-back build; the rollback run
concludes green.

## Set app-specific runtime variables

**Goal:** give the release an environment variable the pipeline does not know
about — an operator password, a retention window, a feature flag.

```bash
# in the app repo
printf 'ACCESS_PASSWORD=%s\nRETENTION_DAYS=14\n' "$(openssl rand -base64 24)" \
  | gh secret set APP_ENV                                   # GitHub
```

On **Gitea**, create a repo Actions secret named `APP_ENV` with the same
`KEY=VALUE` lines as its value.

**What happens:** every workflow that writes the droplet's `.env` (deploy,
rollback, staging) appends the `APP_ENV` secret to it verbatim, after the
variables the pipeline manages (`SECRET_KEY_BASE`, `PHX_HOST`, `DATABASE_URL`,
…). One line per variable, no quoting, no `export`. Unset means nothing is
appended. The next deploy or rollback picks the change up; a running container
does not.

**Verify:** check the app's behavior after a successful deployment. The generated
app services read `.env` through Compose's `env_file`; explicit `environment`
entries such as `PORT` take precedence. Avoid overriding pipeline-owned keys.
Rollback skips migrations, so only code paths actually exercised during startup
are checked before serving. Do not print the full `.env` into shared logs.

## Change the infrastructure

**Goal:** change something in Terraform — droplet size, a firewall rule, a DNS
record.

```bash
# edit <app_dir>/infra/...
git -C <app_dir> commit -am 'infra: ...'
./bootstrap.sh <app_dir>
```

**What happens:** `bootstrap.sh` is idempotent and applies all three Terraform
roots for hosts (or the tenant root). Existing Terraform files are not overwritten.
It also refreshes deployment files and stages all app changes for its pipeline
commit. Commit unrelated work first. Review template changes if you customized
Dockerfiles, Compose, or workflow files.

**Verify:** re-run `./bootstrap.sh <app_dir>` — a clean second run reports no
changes.

## Recreate the droplet

**Goal:** replace the compute (resize, image bump) after confirming recovery of
all data stored on that droplet.

```bash
terraform -chdir=<app_dir>/infra/app destroy
./bootstrap.sh <app_dir>
```

**What happens:** the droplet, firewall and IP binding are destroyed and rebuilt.
Managed Postgres, reserved IP and DNS survive in the separate persistent root.
SQLite volumes do not: verify a current Spaces replica first; the new stack
restores it when no local database exists. Unreplicated writes can be lost.
Caddy certificates and static-site releases are also local to the app droplet;
certificates must be issued again and static sites redeployed. This operation
has downtime. Gitea's separate data-volume design is different.

**Verify:** `https://<domain>` answers again after the redeploy.

> **Redeploy every tenant afterwards.** Their stacks live on that droplet, so
> after recreating it, run `gh workflow run deploy.yml` (or push) in each tenant
> repo. See [Tenancy](tenancy.md).

## Add another app to the droplet

**Goal:** put a second app on a droplet you already have.

```bash
./bootstrap.sh --host <app_dir> <other_app_dir>
```

**What happens:** `<other_app_dir>` is bootstrapped as a **tenant** — it
provisions no droplet, just a DNS record and its own stack on the host's
droplet. Full details in [Tenancy](tenancy.md).

**Verify:** the tenant's own domain answers; `ls /root/apps` on the droplet
shows both slugs (below).

## See what's on a droplet

**Goal:** list the apps and Caddy sites a droplet is serving.

```bash
ssh root@<reserved-ip> 'ls /root/apps && ls /root/caddy/sites'
```

**What happens:** `/root/apps` holds one directory per app (host and tenants);
`/root/caddy/sites` holds one site file per domain.

**Verify:** each deployed app appears under `/root/apps`.

## SSH to the box

**Goal:** get a shell on the droplet.

```bash
ssh root@<reserved-ip>
```

**What happens:** you connect as root. Port 22 is open only to the CIDRs in
`SSH_CIDRS` (your detected IP by default), so this works only from an allowed
address.

**Verify:** you get a shell. If it times out, your public IP probably changed —
re-run the bootstrap (it re-detects) or set `SSH_CIDRS`.

## Tear down

**Goal:** destroy an app and, optionally, its repo.

The scope depends on what the app is. `teardown.sh` reads `.app-type` to decide.

### Preview the scope

```bash
./teardown.sh --plan <app_dir>
```

This lists operations using local metadata without remote calls or credentials.
It is not a Terraform plan and does not verify that remote resources exist.

### A service or host app — everything

```bash
./teardown.sh <app_dir>
```

**What happens:** it prints what it will destroy and asks for confirmation, then
tears down the droplet, firewall, reserved IP, database, DNS records and state
bucket — **data and SQLite backup replicas included**. Add `--yes` to skip the
prompt. The shared registry itself stays; only this app's image repository is
deleted. Destroying a host also removes its tenants' running stacks with the
droplet; remove tenant DNS/state separately before destroying the shared bucket.

### A tenant — just that app

Run the same command against a tenant's directory; `teardown.sh` detects it and
removes only that app: its DNS records, its stack and volumes under
`/root/apps/<slug>`, any staging environment under `/root/apps/<slug>-stg`, and
its routes out of the shared Caddy. The droplet and its other apps are untouched.
(Its Litestream replica in Spaces is left behind — delete `litestream/<project>/`
by hand if you want the data gone.)

### A droplet-free app — nothing to destroy

```bash
./teardown.sh ~/src/mytool                 # "nothing to destroy" — and it means it
./teardown.sh --delete-repo ~/src/mytool   # the repo, and only the repo
```

**What happens:** a `--cli` or `--no-droplet` app created no bucket, cluster,
droplet, DNS record or registry repository, so `teardown.sh` says so and stops —
demanding none of the DigitalOcean, DNSimple or Spaces credentials the rest of
it needs. `--delete-repo` still deletes the code-host repo; the local directory
is never touched either way.

### Deleting the repo

`--delete-repo` deletes the code-host repo along with everything else. On GitHub
it needs the `delete_repo` OAuth scope (`gh auth refresh -s delete_repo`); on
Gitea, `GITEA_TOKEN` must carry delete rights.

### By hand, in the right order

If you'd rather run Terraform directly — e.g. to destroy only the disposable
compute and keep the data:

```bash
# compute only; verify SQLite replicas and plan recovery/redeployment first:
terraform -chdir=<app_dir>/infra/app destroy

# The DB cluster, reserved IP and state bucket are protected with
# prevent_destroy; deliberately flip those flags first, then:
terraform -chdir=<app_dir>/infra/persistent destroy
terraform -chdir=<app_dir>/infra/state destroy
```

If no longer needed, remove this app's image repository with
`doctl registry repository delete <app-name>` and its code-host repository.
The registry can be shared by other apps; `teardown.sh` preserves it.

**Verify:** `https://<domain>` stops answering; the DigitalOcean project shows
no droplet after host teardown.

## Maintain agent docs

Use `agent-docs.sh check`, `diff`, and `update` against the app directory to
update shared guidance without redeploying. Use `configure` for selection changes.
Keep local rules in `.docs/project-guidance.md`; commit the manifests and generated
changes after review. See [Agent docs](claude-docs.md).


## See also

- [Tenancy](tenancy.md) — host apps, tenants, and redeploying after a recreate
- [Reference](reference.md) — every command, flag, script and cost
