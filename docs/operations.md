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
push uses — tests, image build, migration gate, blue/green swap. No new color
serves traffic until it passes its healthcheck.

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
gh workflow run rollback.yml -f tag=<previous commit sha>   # GitHub
```

On **Gitea**, run the `rollback` workflow from the repo's Actions tab (with the
`tag` input), or dispatch it over the API:

```bash
POST .../actions/workflows/rollback.yml/dispatches
```

**What happens:** the pipeline redeploys the image built for `<tag>` and swaps
it into service — same blue/green swap as a forward deploy, no rebuild.

**Verify:** `https://<domain>` serves the rolled-back build; the rollback run
concludes green.

## Change the infrastructure

**Goal:** change something in Terraform — droplet size, a firewall rule, a DNS
record.

```bash
# edit <app_dir>/infra/...
git -C <app_dir> commit -am 'infra: ...'
./bootstrap.sh <app_dir>
```

**What happens:** `bootstrap.sh` is idempotent and applies all three Terraform
roots (`state`, `persistent`, `app`); every step detects work already done and
applies only your change.

**Verify:** re-run `./bootstrap.sh <app_dir>` — a clean second run reports no
changes.

## Recreate the droplet

**Goal:** replace the disposable compute (resize, image bump) without losing
data.

```bash
terraform -chdir=<app_dir>/infra/app destroy
./bootstrap.sh <app_dir>
```

**What happens:** only the droplet, firewall and IP binding are destroyed and
rebuilt. The database, reserved IP, DNS records and issued certificates all live
in the `persistent` root and survive.

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

### A service or host app — everything

```bash
./teardown.sh <app_dir>
```

**What happens:** it prints what it will destroy and asks for confirmation, then
tears down the droplet, firewall, reserved IP, database, DNS records and state
bucket — **data included**. Add `--yes` to skip the prompt.

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
# disposable compute only, data survives:
terraform -chdir=<app_dir>/infra/app destroy

# The DB cluster, reserved IP and state bucket are protected with
# prevent_destroy; deliberately flip those flags first, then:
terraform -chdir=<app_dir>/infra/persistent destroy
terraform -chdir=<app_dir>/infra/state destroy
```

Also delete the container registry (`doctl registry delete`) and the code-host
repo (`teardown.sh --delete-repo`, or by hand) if you're done with them.

**Verify:** `https://<domain>` stops answering; the DigitalOcean project shows
no droplet.

## See also

- [Tenancy](tenancy.md) — host apps, tenants, and redeploying after a recreate
- [Reference](reference.md) — every command, flag, script and cost
