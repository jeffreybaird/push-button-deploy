# Source and test edit ownership contract — schema 2

The user explicitly narrowed the behavior on 2026-09-25: restrict only source
code edits and test-file edits. There is no enforcement-file exception and no
separate restriction on commands, Git delivery, reads, MCP, coordination,
artifacts, documentation, data or agent configuration. The prior accepted
contract and every prior test are preserved byte-for-byte in archive_v1 with
SHA256.json. Historical evidence remains unchanged. Superseded command and
role-wide write prohibitions are intentionally replaced, not weakened to fit
an implementation.

Policy requires schema_version 2, source_globs and test_globs. Tests take
precedence over source matches. These are explicit repository-specific globs;
source directories should match code extensions rather than swallowing nearby
documentation. Legacy artifact_roots/test_commands/protected_globs/delivery
metadata does not confer or remove write permission. Only spec_writer can edit
tests; only implementer can edit source. Other and unknown roles, including
root, cannot edit either. Identity comes from native top-level agent_id and
agent_type; nested tool input is not identity. Other files are outside scope,
including the enforcement files, unless explicitly classified as source/tests.

For recognized direct editing tools, validate all operands of add, update,
delete and move atomically. Claude Write/Edit use file_path, NotebookEdit uses
notebook_path; Codex apply_patch uses command. Malformed recognized edits deny
because ownership cannot be determined. Path aliases, symlinks and hardlinks
must not turn a forbidden source/test edit into an unscoped edit. Existing
parser, ownership, test precedence, CLI and installer preservation guarantees
are retained. Evaluation neither edits nor executes anything.

Allowed and out-of-scope events return exactly {}. They MUST NOT return native
permissionDecision allow, which could override native approvals. Non-edit tools
and missing or malformed non-edit events likewise abstain. Native permissions
remain responsible for command safety and external effects. Shell commands and
MCP tools can write files without direct-edit interception: this is an explicit
coverage limit, not complete filesystem confinement. Invalid policy on a known
direct edit denies. CLI malformed JSON abstains without crashing.

Installer preserves custom settings and guides, native parsability, five role
definitions and byte-idempotence. Fresh installations add no Claude tool
allowlists, broad Edit denies or sandbox overrides. Migration optionally takes
previous_claude_settings from the recorded pre-install baseline: remove only
known v1-injected restrictions absent that baseline, restore the two injected
sandbox keys only when unchanged from the v1-installed values. Never remove
user-owned or post-install user-modified settings. No baseline means preserve
existing settings rather than guessing provenance.

Tests remain mandatory for every behavior change, reviewed before implementation
and frozen after acceptance unless expected behavior explicitly changes.


## Maintenance CLI and installer provenance — authorized 2026-10-02

`python3 workflow.py check|diff|apply` maintains only registered REPO_POLICIES
repositories. Select repeated `--repo NAME` or explicit `--all`, with `--root`
defaulting to the source checkout parent. Apply requires explicit selection.
Unknown names, missing repositories, unsafe symlink destinations, and manifest
keys that are absolute, traverse parents, or fall outside generated-file names
are errors. Preflight every selected repository before any write; no partial
rollout when another selected target fails validation.

Check and diff preserve file bytes, modification times, Git indexes, and native
trust; they do not create missing harness files. Status is missing, drift,
update, current or error. Check/diff exit 0 when current, 1 for action needed,
2 for invalid input. Diff supplies unified previews. JSON stdout contains
command, repositories (each name, status, native_activation UNKNOWN), and
installer (version, source_commit, dirty). Local files never establish native
activation. Apply refuses manifest hash drift or staged/unstaged generated-file
edits (exit 2), while preserving unscoped edits, settings, and custom guidance.
Existing clean, tracked configuration can be adopted. Repeated apply preserves
bytes. The CLI never commits, pushes, connects to a network, or approves trust.

Installer `render(root, policy)` is pure and returns files plus an
install-compatible report; `install` retains the existing API and guarantees.
CLI provenance reads installer_version 0.2.0 from release.json and stamps the
manifest installer object with version and full source_commit. Apply requires a
clean installer Git checkout. Check/diff may preview dirty source but report
dirty true. Older installer metadata requires update without constituting hash
drift. Core API metadata is optional and preserves recorded provenance when
omitted. Existing accepted tests remain unchanged.


Human CLI status help lists changed files for update, including metadata-only
updates, and drift files for manifest integrity differences. Update explains
that generated content or installer provenance differs. Drift supplies actionable
diff and reconciliation guidance, linking MAINTENANCE.md. Native activation
UNKNOWN means host trust and invocation are unverified independently of file
integrity; that uncertainty persists after a successful apply and current check.
JSON statuses and file-list semantics remain compatible; help is presentation.
