# Gitea

[← Docs index](index.md) · push-button-deploy

Use a self-hosted Gitea instance as both your code host and your CI/CD engine,
in place of GitHub.

`GIT_PROVIDER` picks the code host **and** the CI engine in one choice —
GitHub Actions and Gitea Actions both come from the same setting, since the
deploy pipeline is GitHub-Actions-syntax-compatible either way. Set it once,
before the first `./bootstrap.sh`, in `.env` or the environment. `github` is the
default; `gitea` selects the self-hosted path.

## What differs between the two providers

| | `github` (default) | `gitea` (self-hosted) |
|---|---|---|
| Repo host | github.com | your instance (`GITEA_URL`) |
| Auth | `gh auth login` | `GITEA_TOKEN` (personal access token) |
| Repo owner | whichever account `gh` is logged in as | whichever account `GITEA_TOKEN` authenticates as, or `GITEA_OWNER` if set (create under an org instead) |
| CI engine | GitHub Actions, GitHub-hosted runners | Gitea Actions, a **self-hosted** runner you register against the instance |
| Workflow files | `.github/workflows/` | `.gitea/workflows/` |
| CI-runner SSH access | temporary `/32` hole punched per deploy, because a GitHub-hosted runner's IP is unpredictable | `GITEA_RUNNER_IP` allow-listed **once**, statically, in `infra-app/firewall.tf` — the self-hosted runner has a known IP, so there's nothing to punch or revoke |
| Local tool | `gh` | `curl` (already required) + `jq` |
| Repo/secret/variable API | `gh repo`/`gh secret`/`gh variable` | the instance's REST API directly (`scripts/provider.sh`) |
| Run status | `gh run list --json status,conclusion` | the instance's Actions task-listing API, normalized to the same shape |
| Rollback trigger | `gh workflow run rollback.yml -f tag=...` | the repo's Actions tab, or `POST .../actions/workflows/rollback.yml/dispatches` |
| PR staging | on by default (`ENABLE_STAGING`) | **not yet** — see [gaps](#current-gaps) |
| Repo deletion (`teardown.sh --delete-repo`) | needs the `delete_repo` OAuth scope (`gh auth refresh -s delete_repo`) | needs `GITEA_TOKEN` to carry delete rights on the repo |

Everything else — the Terraform roots, the blue/green swap, the database
backends, several apps on one droplet — works identically regardless of
`GIT_PROVIDER`.

## Required Gitea-only env

Three variables are required on the Gitea path, all documented in
`.env.example`:

| Variable | Meaning |
|---|---|
| `GITEA_URL` | the public URL of your instance, e.g. `https://git.example.com` |
| `GITEA_TOKEN` | a personal access token; auth, and the repo owner unless `GITEA_OWNER` is set |
| `GITEA_RUNNER_IP` | the runner's **egress** address (`/32`), allow-listed in the app firewall |
| `GITEA_OWNER` | *optional* — create repos under this org instead of the token's account |

### `GITEA_RUNNER_IP` is an egress address, not a reserved IP

The address Gitea is *served on* and the address its runner *connects out from*
are two different things, and only the second belongs in a firewall rule.
Attaching a DigitalOcean reserved (floating) IP to a droplet does **not** change
its original public IP, and outbound connections keep using that original
address. Get the right value with:

```bash
ssh root@<your-gitea-host> 'curl -s https://api.ipify.org; echo'
```

`bootstrap-gitea.sh` prints it too (the `gitea_egress_ip` Terraform output). It
**changes when the droplet is replaced**, while the reserved IP deliberately
doesn't — so after a `--replace-droplet`, update `GITEA_RUNNER_IP` and re-run
`./bootstrap.sh` for each app to refresh its firewall. The symptom of a stale
value is a deploy job whose `Configure SSH` step takes exactly 5s
(`ssh-keyscan`'s timeout) and then fails on the first `ssh`/`scp`.

### Why the runner IP is static, not punched

The GitHub path's hole-punch exists because GitHub-hosted runners have no fixed
IP — a fresh one is assigned per job, so the firewall is opened and closed
around each deploy. A self-hosted Gitea runner is a machine you control, with an
IP you already know, so it's simpler and no less secure to allow-list it once
(`gitea_runner_cidr`, wired from `GITEA_RUNNER_IP`) than to reimplement a
punch/revoke dance that solves a problem the Gitea path doesn't have.

## Minimum Gitea version: 1.24

This is a hard floor, not a recommendation — 1.24 is the first release carrying
both Actions API routes bootstrap depends on:

| endpoint | used for | 1.22 | 1.23 | 1.24 |
|---|---|---|---|---|
| `/actions/secrets`, `/actions/variables` | seeding CI config | yes | yes | yes |
| `/actions/tasks` | polling the deploy run to confirm LIVE | no | yes | yes |
| `/actions/workflows/{id}/dispatches` | redeploying without a new commit | no | no | yes |

Secret and variable seeding works on older releases, so a too-old instance gets
most of the way through a bootstrap before failing on a 404 for a route that was
never there. `ci_auth_check` therefore reads `/api/v1/version` during preflight
and stops with the version as the reason. If you provisioned with
`bootstrap-gitea.sh`, the pinned tag in `gitea-host/docker-compose.yaml` is
already >= 1.24; re-running that script upgrades in place (data is on the
attached volume, and Gitea migrates on start). Take a volume snapshot first if
you're jumping several minor versions at once.

## Standing up your own instance

`GIT_PROVIDER=gitea` needs an actual instance and a registered Actions runner to
talk to. `bootstrap-gitea.sh` stands both up, reusing the same
DigitalOcean/DNSimple/Spaces credentials `bootstrap.sh` already needs — one
`.env` covers both scripts.

```bash
./bootstrap-gitea.sh --check   # verify prerequisites
./bootstrap-gitea.sh           # provision + configure + start
```

What it does: provisions one dedicated droplet (`infra-gitea/`, its own
Terraform root) running Gitea and its Actions runner **co-located** — simplest
and cheapest, and it makes `GITEA_RUNNER_IP` just that droplet's own egress IP,
allow-listed once. Gitea's data (SQLite DB, git objects, Actions logs) lives on
a separate persistent block-storage volume, so a droplet recreation doesn't lose
it — but that volume is **not itself replicated anywhere**, so snapshot it
yourself for a real backup story. The script also creates the one-time admin
account and API token (`GITEA_ADMIN_EMAIL` is the only new required env var) and
registers the runner. At the end it prints exactly what to add to `.env`:

```
GIT_PROVIDER=gitea
GITEA_URL=https://git.example.com
GITEA_TOKEN=...
GITEA_RUNNER_IP=<droplet-egress-ip>/32
```

It is idempotent like `bootstrap.sh`: a re-run detects an existing admin user or
an already-registered runner rather than redoing it. That matters here because
Gitea shows a token or generated password **once**, at creation; the script
caches both locally (`.gitea-admin-token`, `.gitea-admin-password`, gitignored)
so a re-run doesn't mint new ones.

### Replacing the droplet

Sizing *up* (`GITEA_DROPLET_SIZE`, then re-run) is an in-place resize. Sizing
*down* is refused by DigitalOcean — recreate instead:

```bash
./bootstrap-gitea.sh --replace-droplet
```

That recreates the droplet rather than resizing it, which is safe here: the data
volume (Gitea's DB and repos, Caddy's certs, the runner registration) and the
reserved IP are separate resources, and cloud-init mounts the volume without
formatting it. You keep your repos, accounts, certificates, runner registration
and IP; only Docker and the pulled images are rebuilt.

### Tearing it down

```bash
./teardown-gitea.sh
```

Destroys it all — droplet, firewall, reserved IP, DNS record, and **the data
volume** (every repo, the Gitea DB, all of it). It does not touch any app
deployed through the instance, or the app state bucket.

## Current gaps

Two things aren't ported to the Gitea path yet. Both are workflow-file gaps —
the underlying Terraform, Caddy routing and scripts are already
provider-agnostic — with the same fix when someone wants it.

- **No PR staging environments.** The staging workflow ships only as a
  `.github/workflows/` template, so a Gitea app has nothing to build a PR
  environment with. `bootstrap.sh` turns the feature off on this path (and says
  so once, if you asked for it with `ENABLE_STAGING=true`).
- **Tag-push release uploads are manual.** `--cli` and `--no-droplet` apps get a
  `.gitea/workflows/ci.yml` for every language, but the tag-push step that
  attaches a built escript, `.gem` or npm tarball to a release is omitted —
  Gitea's runners ship no `gh`, and its release API wants a token the automatic
  per-run token isn't guaranteed to carry. A tag push builds and keeps the
  artifact like any other run; cutting the release stays manual.

## See also

- [Staging](staging.md) — the per-PR staging feature (GitHub only for now)
- [Reference](reference.md) — every flag, env var, script and cost
