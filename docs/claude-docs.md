# Agent docs

[← Docs index](index.md) · push-button-deploy

`push-button-deploy` generates an app's agent guidance and manages its future
updates. New services, CLIs, and libraries receive the shared workflow for both
Codex and Claude. Framework modules, starter profiles, and setup hooks are
included where the selected template supplies them.

Applications keep committed, self-contained copies. They do not need this tool
to run their agents; use it when installing or updating shared guidance.
Python 3.11 or newer is required for generation and maintenance.

## Maintain an app

Run the command from any working directory with an explicit app path:

```sh
/path/to/push-button-deploy/agent-docs.sh check /path/to/app
/path/to/push-button-deploy/agent-docs.sh diff /path/to/app
/path/to/push-button-deploy/agent-docs.sh update /path/to/app
```

`check` reports installation status. `diff` previews the changes. Neither writes
to the app. `update` applies reviewed shared changes using the framework and
selections already recorded in the app. Repeating an update with the same inputs
leaves the generated content unchanged.

The app-local `.agent-docs-manifest.json` records selections, component provenance,
and managed content. Keep it under version control with the generated files.
Provenance follows the bundled component and template content, not unrelated
commits in the central repository.

## Install and configure

Normal app generation installs the workflow automatically. To install into an
existing app, or change its selections, use `configure`:

```sh
./agent-docs.sh configure ~/src/myapp --framework phoenix
./agent-docs.sh configure ~/src/myapp --skip-module payment-integration.md
./agent-docs.sh configure ~/src/mytool --app-type cli --framework bash-cli
```

Framework values follow the app generators. Web templates are available for
`phoenix`, `sinatra`, and `zola`; CLI frameworks are `escript`, `ruby-cli`,
`bash-cli`, and `ts-cli`, and the library framework is `mix`. CLI and library
apps receive generic project
entry points and the shared workflow with language-appropriate ownership policy.
The command accepts `--skip-module` and `--skip-agent` repeatedly. Pass `--all`
to `configure` to reset optional selections to their defaults. `--no-setup`
omits the optional template setup hook; `--hook format` selects the template's
formatter hook when available. These template choices do not disable the shared
workflow guards or audit registration. See `./agent-docs.sh --help` for all flags.

Existing `./claude-docs.sh` and `./bootstrap.sh --docs` commands remain compatible
frontends. Their guided framework and module choices use the same lifecycle;
they no longer provide an independent overwrite path. Bootstrap safely adopts an existing app if it has no lifecycle manifest, preserving
its local guidance and settings. It does not refresh docs in an already-managed
app; use the maintenance commands for those updates. `bootstrap.sh --check`
remains read-only.

## What belongs to the app

Put project-specific rules in `.docs/project-guidance.md`. The lifecycle preserves
that file and local text outside bounded generated sections of `AGENTS.md` and
`CLAUDE.md`. It also preserves unrelated native settings and separate hook registrations.
An installed managed hook registration is owned as a unit: editing it, including
adding another hook inside that same registration, is treated as drift. Keep
custom hooks in separate registrations.
Shared modules and generated role definitions are tool-owned; edit their source
templates here if the change should propagate to generated applications.

The installation includes:

- `AGENTS.md` and `CLAUDE.md` entry points, plus framework guidance under `doc/`
  and `.claude/` where templates provide it.
- `.docs/agent-workflow.md`, five role definitions per platform, ownership
  policies, direct-edit guards, and shell-audit hooks.
- Native registration in `.codex/hooks.json` and `.claude/settings.json`.
- The lifecycle manifest and `.codex/hooks/workflow-manifest.json` for workflow
  installation metadata.

Changing selections removes only unchanged content owned by the lifecycle.
Locally edited managed content blocks the update; it is not silently deleted.
Template customization and lifecycle changes are preflighted together before
writes. Symlink destinations and unsafe managed paths are rejected.

## Resolve drift

If `check` reports drift, use `diff` and your app's Git history to identify the
changed managed files. Preserve intentional project-specific text in the app-owned
guidance file. For shared changes, update the central templates or implementation,
then restore the app's managed section to its recorded version and preview again.
Do not edit manifest hashes to hide a conflict. There is no force-overwrite mode.

Preflight detects conflicts before writing, but updates are not a filesystem
transaction. An operating-system write failure can interrupt an update. Review
the app's Git diff and installation status before retrying.

## Runtime and packaging

The tool resolves its bundle independently of the current working directory and
supports a symlinked entry point. `PBD_ROOT` can point at the installed bundle.
The bundle may be read-only and need not contain Git metadata; mutable state
belongs to the target app. Python bytecode caches are not written into the bundle.
Homebrew packaging itself remains separate work; its eventual formula must
provide Python 3.11 or newer.

Installing hooks does not establish native trust or invocation. Review changed
hook definitions when prompted by the host and validate Codex CLI, desktop, and
Claude Code separately. The maintenance tool reports native activation as
`UNKNOWN` and never changes trust settings.

For registered workflow-only repositories and release procedures, see
[Maintaining shared workflows](../scripts/agent-workflow/MAINTENANCE.md).
For migration validation and audit limitations, see
[Migration evidence](agent-workflow-migration.md).
