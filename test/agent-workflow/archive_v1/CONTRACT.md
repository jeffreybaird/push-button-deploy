# Unified native workflow guard contract

These new tests specify policy evaluation, not native hook availability or an
adversarial security boundary. Accepted tests are a behavior contract. After
review acceptance, fix production code rather than weaken the assertions.

`workflow_guard.evaluate_event(platform, event, root, policy)` accepts `codex`
or `claude`, an authentic host PreToolUse event, a real absolute repository root,
and a policy dictionary. It returns the native `hookSpecificOutput` object with
`hookEventName: PreToolUse`, `permissionDecision: allow|deny`, and a nonempty
`permissionDecisionReason`. Invalid or unsupported input returns a denial.
Evaluation itself never edits files or executes commands.

Policy schema version 1 contains `test_globs` (repository-relative patterns,
including test fixture and colocated test patterns), `artifact_roots` (relative
directories), and `test_commands` (exact argv arrays). Unrecognized schema or
malformed policy denies. Policy is trusted configuration stored with the hook,
not supplied by an agent through tool input.

Top-level nonblank `agent_id` and `agent_type` identify child roles. Recognize
plain role names and `workflow_` names; underscore/hyphen spellings normalize.
The five roles are spec_writer, implementer, runner, reviewer, orchestrator.
Absent identity allows parent inspection and coordination only; malformed or
unknown identity never grants mutations. Nested role claims are not identity.
Only the root parent or orchestrator may delegate via spawn_agent/Agent/Task.

Spec writer owns policy-matched tests. Implementer owns other repository files,
except artifacts and protected policy/control paths. Runner owns artifact
directories only. Reviewer and orchestrator have no file-edit authority.
Protect .git, .codex, .claude, AGENTS.md, CLAUDE.md, and .docs/agent-workflow.md
against every role, including when nested beneath test or artifact directories.
Reject traversal, symlink targets/ancestors, external paths, directory targets,
and multi-link existing regular files. Absolute paths inside root are supported.

Codex canonical apply_patch uses tool_input.command; parse complete add, update,
delete, and move operations and authorize every path before allowance. Claude
Write/Edit use file_path and NotebookEdit uses notebook_path. Unsupported edit
shapes/tools deny. Claude Read/Grep/Glob are inspection tools and are allowed.

Codex exec_command/Bash and Claude Bash use string command input. Permit narrowly
parsed read commands (cat, selected rg, git status and git diff without external
diff/text conversion). Reject redirection, shell operators/substitution, git
configuration overrides, write-capable search flags, general interpreters,
scripts, and unsupported flags/commands. Explicit tool cwd/workdir, when given,
must be the configured root. Interactive continuations and arbitrary MCP tools
deny. Runner alone may execute the exact policy-approved test argv, without
operators, command prefixes, or additional flags. These approved commands run
repository code and remain a practical guardrail, not process confinement.
Delivery commands are not part of this guard version's shell allowance; parent
delivery requires a separately scoped adapter. Denying write_stdin in this pure
function does not establish native interception of continuations: Codex does
not rerun PreToolUse on write_stdin. Shell starts requesting a PTY are denied.

CLI: `workflow_guard.py --platform codex|claude --root ROOT --policy POLICY_JSON`
reads one event JSON from stdin and emits the same decision JSON. Malformed
event JSON or unreadable/malformed policy yields an explicit denial with exit
zero rather than a hook crash. Accidental native hook failure is an accepted
limitation; this suite does not require a new supervisor or OS isolation.

## Installer

`installer.install(root: Path, policy: dict) -> dict` renders the setup into a
real repository directory. Validate policy and reject symlink configuration
destinations before any mutation. Existing project instruction text remains;
generated bounded sections reference agent-workflow and replace idempotently.
Write `.docs/agent-workflow.md`, five `workflow_<role>.toml` Codex definitions
and five `workflow-<role>.md` Claude definitions (either underscore/hyphen
spelling accepted), and exact shared guard copies plus policy.json under each
platform's protected hooks directory. Native JSON/TOML remains parseable.
Preserve unrelated settings, hooks, and TOML keys. Remove only recognized
protect-tests.sh legacy hook registrations, retaining the scripts themselves.
Repeated install with identical policy produces identical file bytes.
