# Agent docs

[← Docs index](index.md) · push-button-deploy

`push-button-deploy` generates an app's agent guidance and manages its future
updates. New services, CLIs, and libraries receive the shared workflow for both
Codex and Claude. Framework modules, starter profiles, and setup hooks are
included where the selected template supplies them.

Applications keep committed, self-contained copies. They do not need this tool
to run their agents; use it when installing or updating shared guidance.
Python 3.11 or newer is required for generation and maintenance.

Generated coordination guidance defaults to one main orchestrator per change,
reusing role agents with compact handoffs and completion, blocker, or material
finding reports. Codex uses bounded context with explicit task context by
default. Event-driven waits limit repeated status chatter; full saved evidence,
independent review, ownership, and all quality gates remain required.

Projects may keep an optional `.docs/agent-models.json` with `schema_version: 1`
and `codex`/`claude` objects. Each accepts a main `model` and a `roles` object
keyed by `spec_writer`, `implementer`, `runner`, `reviewer`, or `orchestrator`.
Role settings accept `model` and native `model_reasoning_effort` (Codex) or
`effort` (Claude). No model is selected by default. The project owns this file;
the updater reads and validates it without changing its bytes or recording it
in generated manifests. Native hosts determine model availability.

For example:

```json
{
  "schema_version": 1,
  "codex": {
    "model": "gpt-6.1-sol",
    "roles": {
      "reviewer": {"model": "gpt-6-astra"},
      "runner": {"model": "gpt-6-luna", "model_reasoning_effort": "low"}
    }
  }
}
```

Preview with `diff`, then apply with `update` (or registered workflow `apply`).
Omitted platforms and main models preserve current native settings. Removing a
main model keeps the current native main selection; change that native setting
explicitly if needed. Removing a role override restores inheritance on update.
See `.docs/agent-workflow.md` in the app for supported effort values and safety
checks. Model selection leaves hook trust, policy, and role instructions intact.

The shared workflow includes Elixir doctest requirements for Phoenix, escript,
and Mix library projects: representative happy paths, matching predicate inputs,
stable time-dependent examples, and verified ExUnit registration and execution
for every module containing doctests in the normal `mix test` suite and CI.
Fallback-only examples do not satisfy these requirements. New installations and
shared updates receive this guidance for both Codex and Claude.

PR descriptions include relevant acceptance scenarios and actual readable test
output: RSpec `--format documentation` for Ruby, and Cucumberex `--format pretty`
with focused ExUnit `--trace` output for Elixir. Normal full quality gates still
apply. Fresh Rails/Sinatra apps include RSpec and Cucumber; fresh Phoenix, Elixir
CLI and Mix-library apps include ExUnit and Cucumberex independently of optional
docs selection. Missing required tools in those starters is a defect, not an
`N/A` exception. A docs update changes guidance only; it does not install missing
application test dependencies or retrofit existing CI.

Across all frameworks, every PR must review dead code, remove confirmed unused
code, and propose a concrete unapplied patch for tests solely covering that
behavior. Test deletion requires explicit user approval; tests remain unchanged
until approval, and role ownership and hook restrictions still apply. If hooks
block an approved deletion, present the exact patch and blocker without bypassing
them. Retain live-behavior coverage and report removals, pending approval or
blockers, or that no dead code was found. Generated reviewer instructions reinforce
these requirements.

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
`phoenix`, `sinatra`, `rails`, `zola`, and `react`; CLI frameworks are `escript`, `ruby-cli`,
`bash-cli`, and `ts-cli`, and the library framework is `mix`. CLI and library
apps receive generic project
entry points and the shared workflow with language-appropriate ownership policy.
Use explicit `escript`, `mix`, or `ruby-cli` for those apps: inference treats
`config/application.rb` as Rails before checking `Gemfile` as Sinatra;
`mix.exs` identifies Phoenix. `package.json` declaring React and React DOM infers `react`; other packages infer `ts-cli`;
an empty directory or Bash CLI needs an explicit framework.

The command accepts `--skip-module` and `--skip-agent` repeatedly. Each supplied
option replaces that category's complete skip list; omitted categories retain
their saved choices. Pass `--all` to `configure` to reset selections to their
defaults, then add any desired skips. `--no-setup`
omits the optional template setup hook; `--hook format` selects the template's
formatter hook when available. These template choices do not disable the shared
workflow guards or audit registration. Reset with `--all` to restore the setup
hook. See `./agent-docs.sh --help` for all flags.

The optional formatter hook runs project-wide after Claude writes: `mix format`
for Phoenix, `bundle exec rubocop -A --fail-level fatal` for Sinatra. Failures are
ignored by those hooks, and RuboCop is not included in the starter Gemfile.
Treat formatting as a separate reviewed operation where role-owned source/test
boundaries require it; selecting the hook does not install formatter dependencies.

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

- `AGENTS.md` and `CLAUDE.md` entry points, both referencing one shared copy of
  framework supporting guides under `.docs/` where templates provide them.
- `.docs/agent-workflow.md`, five role definitions per platform, ownership
  policies, direct-edit guards, and shell-audit hooks.
- Native registration in `.codex/hooks.json` and `.claude/settings.json`.
- The lifecycle manifest and `.codex/hooks/workflow-manifest.json` for workflow
  installation metadata.

Changing selections removes only unchanged content owned by the lifecycle.
Locally edited managed content blocks the update; it is not silently deleted.
Template customization and lifecycle changes are preflighted together before
writes. Symlink destinations and unsafe managed paths are rejected.

Updates migrate unchanged managed supporting guides from the older `.claude/`
and `doc/` layouts into `.docs/` and update both entry points. Native agent
definitions, settings and hooks retain their tool-specific locations. App-owned
`.docs/project-guidance.md` remains separate from the generated supporting guides.
Locally edited legacy guides or conflicting files already at the destination
block migration rather than being overwritten. If you have moved guides manually,
review `diff` and resolve the reported drift before updating; do not change
manifest hashes to bypass these checks.

The internal custom-template renderer also writes supporting guides under
`.docs/`, but retains its existing selected-file rendering behavior. It has no
lifecycle ownership record and does not remove older guide copies. The migration
and drift checks above apply to bundled framework installations managed through
`agent-docs.sh` and its compatible frontends.

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
