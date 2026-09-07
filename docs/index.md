# push-button-deploy documentation

One command takes you from an empty directory to a running app — a web service on
its own HTTPS droplet, or a command-line program / library built and tested by
CI — with a pipeline that deploys every push to `main` from then on.

This is the full guide. The [README](../README.md) is the short overview; start
there if you just want the pitch and a three-command quickstart.

## Start here

- **New to the tool?** Read [Concepts](concepts.md) for the mental model, then
  follow the [Quickstart worked example](quickstart.md).
- **Just want it running?** [Prerequisites](prerequisites.md) →
  [Quickstart](quickstart.md).
- **Looking up a flag or env var?** [Reference](reference.md).
- **Something broke?** [Troubleshooting](troubleshooting.md).

## "I want to…"

| Task | Go to |
|---|---|
| Understand how it all fits together | [Concepts](concepts.md) |
| Install the tools and set my credentials | [Prerequisites](prerequisites.md) |
| Stand up my first app, step by step | [Quickstart](quickstart.md) |
| Build a CLI or a library instead of a web app | [App types](app-types.md) |
| Choose Phoenix vs Sinatra vs Zola | [Frameworks](frameworks.md) |
| Choose SQLite vs Postgres | [Databases](databases.md) |
| Get a staging environment on every pull request | [Staging](staging.md) |
| Put a second app on a droplet I already have | [Tenancy](tenancy.md) |
| Use self-hosted Gitea instead of GitHub | [Gitea](gitea.md) |
| Generate or tailor an app's CLAUDE.md / .claude docs | [Claude Code docs](claude-docs.md) |
| Deploy a change, roll back, or tear down | [Operations](operations.md) |
| Fix an error or answer a "why did it…" | [Troubleshooting](troubleshooting.md) |
| Look up every command, flag, script and cost | [Reference](reference.md) |

## All pages

| Page | What it covers |
|---|---|
| [Concepts](concepts.md) | Architecture and mental model: app types × frameworks, the Terraform roots, blue/green, Caddy, lifecycle isolation |
| [Prerequisites](prerequisites.md) | Required tools, accounts and credentials, the full `.env` reference, `--check` |
| [Quickstart](quickstart.md) | A single service from empty directory to live HTTPS, step by step — plus a droplet-free quickstart |
| [App types](app-types.md) | `service` / `cli` / `library`, the language↔framework table, and interactive selection |
| [Frameworks](frameworks.md) | Phoenix, Sinatra and Zola specifics — generation, CI gate, migrations, image/release |
| [Databases](databases.md) | SQLite (Litestream) vs managed Postgres — tradeoffs and conversion caveats |
| [Staging](staging.md) | Per-PR staging environments — how they work and how to turn them off |
| [Tenancy](tenancy.md) | Several apps on one droplet — host apps and tenants |
| [Gitea](gitea.md) | Self-hosted Gitea as code host and CI engine |
| [Claude Code docs](claude-docs.md) | Generating and tailoring an app's `CLAUDE.md` + `.claude/` |
| [Operations](operations.md) | Day-2: deploy, watch, roll back, recreate, add an app, tear down |
| [Troubleshooting](troubleshooting.md) | Symptom → fix table and FAQ |
| [Reference](reference.md) | Commands, flags, env vars, scripts, Terraform roots, costs, security |

---

### Conventions used in these docs

- Commands are shown exactly as you run them from the repo root; `<app_dir>`,
  `<domain>` and the like are placeholders you replace.
- Every how-to states its **goal**, the **commands**, **what happens**, and how
  to **verify** it worked.
- "Service" means a web app on a droplet; "droplet-free" means a `--cli` or
  `--no-droplet` build that provisions no infrastructure.
