# Maintaining shared agent workflows

`push-button-deploy` owns app generation and subsequent agent-document updates.
Applications commit their generated files and remain self-contained. Put local
project rules in `.docs/project-guidance.md`; maintain shared templates and hook
implementation in this repository.

Use the app lifecycle command for generated applications:

```sh
/path/to/push-button-deploy/agent-docs.sh check /path/to/app
/path/to/push-button-deploy/agent-docs.sh diff /path/to/app
/path/to/push-button-deploy/agent-docs.sh update /path/to/app
```

See [Agent docs](../../docs/claude-docs.md) for initial installation, selections,
ownership boundaries, drift reconciliation, and runtime requirements.

## Registered repositories

The historical registry remains in `repo_policies.py` for maintaining existing
workflow-only installations. These commands do not install framework modules:

```sh
python3 -B scripts/agent-workflow/workflow.py check --all --root /path/to/projects
python3 -B scripts/agent-workflow/workflow.py diff --repo heybridge --root /path/to/projects
python3 -B scripts/agent-workflow/workflow.py apply --repo heybridge --root /path/to/projects
```

Use explicit `--root` when maintaining registered repositories. Repeat `--repo`
to select several, or use `--all`. The registry is a compatibility feature;
new applications do not need registration. Inspection is read-only. Apply
preflights every selected repository before writing, rejects drift and local
managed edits that would be overwritten, and never commits, pushes, fetches, or
changes native hook trust.

## Release and verification

Follow `.docs/agent-workflow.md` when changing this component: test writer,
authoritative red, independent test acceptance, implementation, authoritative
green, and independent final review. Preserve archived contracts and compare
accepted test hashes. Run `bash test/run.sh` from the repository root.

The component release is recorded in `release.json`. Installed provenance uses
a deterministic content fingerprint, independent of the repository's Git HEAD.
Changes to inputs that generate app files can require updates; unrelated commits
do not. Release and workflow-contract versions are separate identifiers.

Preview a representative app before applying a new release. Review its generated
diff and run its own checks before committing it. Update other repositories only
within the user's authorized scope. Filesystem preflight is not a transaction:
an operating-system failure during writes can leave partial changes. Inspect
both manifests and the Git diff before retrying.

## Native activation

File installation does not verify native hook trust or invocation. The CLI
reports native activation as `UNKNOWN`. Review new definitions through the
host's hook-review UI where required; the installer never approves itself.
Validate Codex CLI, Codex desktop, and Claude Code separately in a disposable
workspace. Record host version, reviewed definitions, allowed and denied role
probes, restart behavior, and invocation from nested or relocated checkouts.

The direct-edit guard enforces source/test ownership for supported native edit
events. Shell auditing observes changes and records overlap; it is not complete
filesystem confinement. Keep secrets out of commands because audited command
text is retained. Review ambiguous audit violations against overlapping tool
calls rather than assuming authorship.

## Historical source

The implementation and active tests were migrated from `agent-workflow-setup`.
Archived version-one contracts remain under `test/agent-workflow/archive_v1`.
The original repository retains its history and historical native-validation
evidence; that evidence does not establish activation in newly generated apps.
