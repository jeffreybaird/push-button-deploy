# Combined agent-document lifecycle migration contract

The user authorized consolidating agent-workflow-setup into push-button-deploy,
with generated apps managed by that combined tool for all future agent docs.
Homebrew packaging is deferred; a relocated bundle and public launcher must work
without a source Git checkout, source writes, or assumptions about caller cwd.

Phase 1 imported the active workflow suite with source-path adaptation only;
archive_v1 remains byte-identical. Phase 2 explicitly supersedes the old
maintenance provenance requirement of a clean standalone Git checkout: the
legacy source_commit field now carries a stable 64-hex component content digest,
not Git HEAD. Relevant component edits change it; unrelated files/commits do not.
The compatibility command still targets registered Git roots and retains its
staged/unstaged managed-file protections. It rejects lifecycle-owned targets
with an actionable agent-docs.sh direction before writing.

The public agent-docs.sh accepts check, diff, update, configure, an explicit
arbitrary target directory, and --json. Fresh installation accepts --framework
for all eight current stacks; --app-type must match the stack. Defaults follow
the existing all-content generation behavior. The manifest is
.agent-docs-manifest.json with framework, app_type, selection and owned files.

Selection options: repeated --skip-module and --skip-agent basenames, --hook
format, --no-setup. configure applies explicit choices; --all resets defaults.
check/diff/update reuse the recorded selection when no options are supplied.
Legacy claude-docs.sh --all on an installed app preserves the recorded selection;
configuration changes belong to configure. Known bundled cd_inject paths share
the lifecycle. The existing arbitrary-template renderer fixture retains its old
low-level contract; arbitrary external templates are not advertised lifecycle
inputs in this migration.

JSON is a flat object with status (missing/current/update/drift/error) and
native_activation UNKNOWN. Check/diff exit 0 current, 1 action needed, 2 invalid;
update/configure exit 0 success or 2 invalid/drift. Human diff includes unified
file changes. No command commits, contacts a network, or approves native trust.

Both platform entry points, workflow roles, native hooks and shared framework
guidance are installed for every framework and app type, through bootstrap's
existing ensure_app and prepare_app paths. App-specific rules reside in
.docs/project-guidance.md and remain app-owned. Custom entry-point sections,
unrelated native settings, hooks and TOML fields remain intact, including edits
after install. Only managed regions/keys/registrations count toward drift.

Update renders current bundled templates, detects local managed drift before
any write, previews updates without changing bytes or mtimes, and preserves
bytes and mtimes on no-op updates. Selection removal deletes only intact owned
files/hooks; changing a managed file then deselecting it still rejects. Removing
cloud setup never removes required native workflow registrations. Existing
Zola/no-setup tests are revised only to require workflow settings while keeping
SessionStart absent; template agent profiles still use their platform paths.

Validate target aliases, managed parent/file symlinks, path traversal and invalid
selections before writes. Manifest keys cannot claim paths outside the target.
Generated apps are self-contained and need no Git repository for docs installs.
