# Claude Code docs

[← Docs index](index.md) · push-button-deploy

Every app this tool generates ships **Claude Code docs**: a `CLAUDE.md` project
guide plus a `.claude/` directory of guidance modules, starter subagents, and a
`SessionStart` hook that prepares cloud sessions. This page explains what those
are, how to generate them for any app (guided or not), how to tailor what lands,
and how the template system works.

## What gets generated

Into the app directory:

```
CLAUDE.md                 the top-level project guide Claude Code reads every session
.claude/
  *.md                    guidance modules — core ones always, optional ones you pick
  agents/*.md             starter subagents (test-writer, code-reviewer)
  settings.json           a SessionStart hook that prepares cloud sessions
  cloud-setup.sh          the script that hook runs
```

The docs come from static **template roots** in this repo, copied into the app
with the `MyApp`/`my_app` placeholders (or `My Site`/`my_site` for Zola)
rewritten to the app's real name:

| Framework | Template root | Placeholders |
|---|---|---|
| Phoenix | `app-template/` | `MyApp` / `my_app` |
| Sinatra | `app-template-ruby/` | `MyApp` / `my_app` |
| Zola | `app-template-zola/` | `My Site` / `my_site` |

A normal `bootstrap.sh` run injects **everything** automatically. You only need
the commands below to generate docs on their own, retrofit an existing repo, or
**choose** what lands.

> CLI and library app types (`--cli`, `--no-droplet`) ship no docs yet — the
> engine is ready for them, but the template roots aren't written.

## Core vs optional modules

A framework's `CLAUDE.md` indexes its `.claude/*.md` modules in two groups.
**Core** modules always ship. **Optional** modules ship by default but can be
left out; skipping one also removes its line from the `CLAUDE.md` index, so the
guide never points at a file that isn't there.

The optional modules (Phoenix and Sinatra):

| Module | For |
|---|---|
| `multi-tenancy.md` | tenant scoping, query patterns, test isolation |
| `rbac.md` | roles, enforcement, authorization |
| `external-service-integration.md` | wrapping a third-party API behind a client |
| `payment-integration.md` | billing / subscriptions / checkout |
| `object-storage-integration.md` | S3-compatible file/blob storage |

Zola ships three core docs (`content.md`, `templates.md`, `deployment.md`), no
optional modules, no agents and no hook.

## The command

`./claude-docs.sh` generates the docs on their own — guided by default, off the
same templates, provisioning nothing.

```bash
./claude-docs.sh                       # guided; framework inferred from the cwd
./claude-docs.sh ~/src/myapp           # guided, into that directory
./claude-docs.sh --framework sinatra ~/src/myapp
./claude-docs.sh --all ~/src/myapp     # non-interactive: include everything
./claude-docs.sh --help
```

| Option | Meaning |
|---|---|
| `--framework, -f <name>` | `phoenix`, `sinatra` or `zola`. Inferred from the app's marker file (`mix.exs` / `Gemfile` / `config.toml`) when omitted; you are prompted if it can't be inferred. |
| `--all` | include everything without prompting (works with no terminal) |
| `--help, -h` | usage |
| `<app_dir>` | target directory (defaults to `.`) |

It writes only `CLAUDE.md` and `.claude/` — never your code.

## How-to

### Generate docs for a brand-new app

Goal: put a tailored set of Claude docs into a fresh or existing app directory.

```bash
./claude-docs.sh ~/src/myapp
```

What happens: it detects the framework from the directory's marker file (or asks),
walks you through each optional module, each starter agent, and the hook
(defaulting to *include* at every step), shows a recap, writes the files, then
offers to open `CLAUDE.md` in your editor.

Verify: `ls ~/src/myapp/.claude` shows the modules you kept;
`grep -r MyApp ~/src/myapp/CLAUDE.md` returns nothing (placeholders were
rewritten).

### Retrofit an existing repo

Goal: add Claude docs to a repo that doesn't have them, without touching its code.

```bash
./claude-docs.sh --framework phoenix ~/src/existing-app
```

What happens: same guided flow. Only `CLAUDE.md` and `.claude/` are created or
overwritten; nothing else in the repo is touched. (For a Phoenix app you can also
use `./scripts/inject-skill-docs.sh <app_dir>`, which additionally injects the
`req`/`oban`/`cucumberex` deps the docs assume into `mix.exs`.)

### Take everything, non-interactively

Goal: script the injection, or run it where there's no terminal (CI, a pipe).

```bash
./claude-docs.sh --all --framework sinatra ~/src/myapp
```

What happens: every module, both agents and the SessionStart hook are written
with no prompts. `--all` needs an explicit `--framework` if the directory has no
marker file to infer from.

### Do it from bootstrap

Goal: generate docs via the main entry point, without provisioning anything.

```bash
./bootstrap.sh --docs ~/src/myapp
```

`--docs` delegates straight to `./claude-docs.sh` (guided, no provisioning). If
`FRAMEWORK` is set in your environment it is honored; otherwise the framework is
inferred or prompted.

### Tailor docs while bootstrapping a new app

Goal: pick which docs land as part of a full `--interactive` bootstrap run.

```bash
./bootstrap.sh --interactive ~/src/myapp
```

During the interactive flow, after you choose the app type and language, answer
**yes** to *"Customize which Claude docs (modules, agents, hooks) the app gets?"*
You'll get the same per-module / per-agent / hook prompts; your choices flow
through to the app that's generated moments later. Answer **no** (the default) to
take everything.

### Add the "format on write" hook

Goal: have Claude Code run the formatter after every edit.

During a guided run, when asked about the SessionStart hook, accept it, then
answer **yes** to the `format` hook. This installs a `PostToolUse` hook that runs
`mix format` (Phoenix) or `rubocop -A` (Sinatra) after `Edit`/`Write`/`MultiEdit`.
It never blocks (`|| true`) and runs project-wide, so expect it to reformat more
than the file you touched.

### Open the result in your editor

At the end of a guided run you're asked whether to open `CLAUDE.md`. It uses
`$VISUAL`, then `$EDITOR`, then `vi`. Skip it with **no** (the default) or by
running non-interactively.

## Manifest format (reference)

Each template root carries a `claude-docs.manifest` that declares what the
injector offers. It is never copied into the app.

```
# role|arg1|arg2  (blank lines and #-comments ignored)
placeholders|MyApp|my_app                       # the two strings rewritten to the app's name
optional|rbac.md|roles, enforcement, authorization
agent|test-writer.md|drafts tests to the testing rules
hook|format|also run the formatter on file writes (PostToolUse)
```

- `placeholders|<Module>|<app>` — the two search strings the rewrite replaces
  (module name and app name). Defaults to `MyApp`/`my_app` when absent.
- `optional|<file.md>|<summary>` — a `.claude/` module the user may skip. Every
  `.claude/*.md` NOT listed here is core (always included).
- `agent|<file.md>|<summary>` — a `.claude/agents/` file the user may include.
- `hook|<id>|<summary>` — an optional hook variant. `format` swaps `settings.json`
  for `settings.<id>-hook.json`.

If a template root has no manifest, the injector includes everything and prompts
for nothing — the safe default.

## Under the hood

All paths share one injector, `scripts/claude-docs.sh`, so a guided run and an
automatic bootstrap run place docs identically:

- `scripts/prompt.sh` — the interactive prompt primitives (also used by
  `bootstrap.sh --interactive`).
- `scripts/claude-docs.sh` — the manifest-driven copy + placeholder rewrite +
  index prune + guided selection.
- `bootstrap.sh` and the framework scaffolds (`scripts/inject-skill-docs.sh`,
  `scripts/new-sinatra-app.sh`, `scripts/new-zola-site.sh`) all call into it.
  Non-interactively (skip nothing) they reproduce the historical "copy it all"
  behavior, plus the starter agents the templates now ship.

## Test it

An offline smoke test covers the injector across all three frameworks (copy,
placeholder rewrite, optional-module prune, agent/hook selection, `bash -n`):

```bash
./test/claude-docs-smoke.sh
```

It needs no network and no `mix`/`bundle`/`zola` — just bash, awk and perl.

## Troubleshooting

See [Troubleshooting](troubleshooting.md) for: framework can't be inferred, a
guided run in a no-terminal context, and placeholder-collision edge cases.
