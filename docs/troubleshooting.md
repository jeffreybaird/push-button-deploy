# Troubleshooting

[← Docs index](index.md) · push-button-deploy

Symptoms and fixes, then a short FAQ. If your issue is conceptual ("why does it
work this way"), [Concepts](concepts.md) is a better start.

## Bootstrap and deploy

### `--check` fails on a tfvars file

The script injects all Terraform variables via the environment; a
`terraform.tfvars` in an infra root would silently override them (Terraform
precedence). Move the file aside as the message instructs, then re-run.

### `project_name is immutable`

The requested `PROJECT_NAME` doesn't match what's in Terraform state. Renaming it
would force the DB cluster to be replaced, so the script refuses. Keep the old
name — `PROJECT_NAME` is infra-naming only and is independent of the app name.

### Timeout with "CI still running"

Not a failure. First deploys compile everything from a cold cache (~5–10 min).
Watch it with `gh run watch` (GitHub) or the repo's Actions tab (Gitea); it will
go green on its own.

### "deploy succeeded but HTTPS not answering"

Usually DNS propagation or first-time Let's Encrypt issuance. The `dig` output and
Caddy logs the script prints on timeout localize it. Give the certificate a minute
on the very first request.

### SSH timeouts from your machine

Your public IP changed, so it's no longer in the droplet's allowed SSH CIDRs.
Re-run the bootstrap (it re-detects your IP) or set `SSH_CIDRS` explicitly. See
[Prerequisites](prerequisites.md) for the variable.

### Re-running refuses to apply against a Postgres app

Because the database default is `sqlite`, re-running the bootstrap against an
existing **Postgres** project without setting `DATABASE_BACKEND=postgres` would
ask Terraform to tear the cluster down. The script detects a cluster in state and
**refuses** rather than risk it. Set `DATABASE_BACKEND=postgres` (in `.env` or the
environment) and re-run. See [Databases](databases.md).

## Gitea

### A Gitea deploy's "Configure SSH" step takes exactly 5s, then fails

That 5s is `ssh-keyscan`'s timeout — the symptom of a stale `GITEA_RUNNER_IP`.
The runner's egress IP changes when its droplet is replaced (the reserved IP does
not). Update `GITEA_RUNNER_IP` to the current egress address and re-run
`./bootstrap.sh` for each app to refresh its firewall. See [Gitea](gitea.md).

### Bootstrap fails on a 404 partway through a Gitea run

The instance is older than the required **1.24** floor — secret/variable seeding
works on older releases, so it gets most of the way before hitting a route that
was never there. Preflight now reads `/api/v1/version` and stops with the version
as the reason. Upgrade the instance (re-running `./bootstrap-gitea.sh` upgrades in
place). See [Gitea](gitea.md).

## Claude Code docs

For the full feature, see [Claude Code docs](claude-docs.md).

### "could not infer the framework"

`claude-docs.sh` guesses the framework from a marker file (`mix.exs` /
`Gemfile` / `config.toml`). A fresh or empty directory has none. Pass it
explicitly:

```bash
./claude-docs.sh --framework phoenix ~/src/myapp
```

### "input closed — this mode needs a terminal"

The guided flow reads from `/dev/tty`; you ran it where there's no terminal (a
pipe, a CI step). Use the non-interactive path, which needs an explicit framework:

```bash
./claude-docs.sh --all --framework sinatra ~/src/myapp
```

### An optional module I skipped is still referenced

It shouldn't be — skipping a module also removes its bullet from the `CLAUDE.md`
index. If you edited `CLAUDE.md` by hand and re-ran, the template wins on re-run
(docs are overwritten); your own files are never touched. Re-run and re-apply your
edits, or keep them in a section the template doesn't own.

## Interactive mode

### "--interactive needs a terminal"

Interactive mode reads answers from `/dev/tty`. With no TTY it stops and points
you back at the flags. Use the flags directly (see `./bootstrap.sh --help`) or run
in a real terminal.

## FAQ

**Do I need Docker installed locally?** No. Images build in CI. Docker is only on
the droplet.

**Does a CLI or library need DigitalOcean/DNSimple/Spaces credentials?** No.
Droplet-free types (`--cli`, `--no-droplet`) need only `git`, `curl` and the code
host's tool. See [App types](app-types.md).

**I bootstrapped an app before the starter agents existed — what changed?** A
normal (non-interactive) `bootstrap.sh` run now also emits the two starter agents
(`test-writer`, `code-reviewer`) under `.claude/agents/`. Docs are otherwise
identical. Retrofit an existing app with `./claude-docs.sh <app_dir>`.

**Can I switch a live app between SQLite and Postgres by flipping the flag?** No.
The flag only affects newly generated apps; converting a live app is a data
migration. See [Databases](databases.md).

**How do I see what's running on a droplet?**

```bash
ssh root@<reserved-ip> 'ls /root/apps && ls /root/caddy/sites'
```

**Where do I find every flag and environment variable?** [Reference](reference.md).
