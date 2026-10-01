# Agent workflow — version 2.0.0

Every behavior change requires this pipeline: orchestrator defines expected
behavior; spec writer writes tests; runner demonstrates the expected failure;
reviewer accepts the tests before implementation; implementer changes code;
runner verifies green; reviewer independently checks implementation and final
diff. Repeat findings through the responsible role. The orchestrator coordinates
delegation as a workflow responsibility, not a hook permission restriction.

Claude subagents cannot start other subagents, so in Claude Code the
main session acts as orchestrator: it delegates each step to the workflow-*
agents and makes no source or test edits itself. Codex may use
workflow_orchestrator directly.

Accepted tests are the contract. Never weaken an accepted test to accommodate
an implementation defect. Changes to expected behavior require a test-writer
revision and renewed reviewer acceptance. New regression tests are permitted.
Record hashes of accepted tests before implementation and compare afterward.

## Scope and roles

- Spec writer owns edits to matched tests and test fixtures.
- Implementer owns edits to matched source files, excluding matched tests.
- Runner, reviewer, orchestrator and parent sessions do not edit source or tests.
- All roles may edit unscoped files, including documentation and artifacts.
- Commands, inspection, Git operations, MCP tools and coordination are outside
  this hook's restrictions. Native permissions and user authorization still apply.

Tests take precedence when a path matches both lists. Repository-relative source
patterns identify code extensions and named build files, rather than every file
in a source directory. The policy copies live at `.codex/hooks/policy.json` and
`.claude/hooks/policy.json`:

```json
{
  "schema_version": 2,
  "source_globs": [
    "bootstrap.sh",
    "bootstrap-gitea.sh",
    "teardown.sh",
    "teardown-gitea.sh",
    "claude-docs.sh",
    "scripts/*.sh",
    "deploy/*.sh",
    "deploy/*.yaml",
    "deploy/*.yml",
    "deploy/*.tmpl",
    "deploy/Caddyfile",
    "app/Dockerfile",
    "app/Dockerfile.ruby",
    "app/.dockerignore",
    "app/.dockerignore.ruby",
    "app/.github/workflows/*.yml",
    "app/.gitea/workflows/*.yml",
    ".github/workflows/*.yml",
    "infra-app/*.tf",
    "infra-app/*.hcl",
    "infra-app/*.yaml",
    "infra-app/*.yml",
    "infra-gitea/*.tf",
    "infra-gitea/*.hcl",
    "infra-gitea/*.yaml",
    "infra-gitea/*.yml",
    "infra-persistent/*.tf",
    "infra-persistent/*.hcl",
    "infra-persistent/*.yaml",
    "infra-persistent/*.yml",
    "infra-state/*.tf",
    "infra-state/*.hcl",
    "infra-state/*.yaml",
    "infra-state/*.yml",
    "infra-tenant/*.tf",
    "infra-tenant/*.hcl",
    "infra-tenant/*.yaml",
    "infra-tenant/*.yml",
    "gitea-host/*.yaml",
    "gitea-host/*.yml",
    "app-template/.claude/cloud-setup.sh",
    "app-template/.claude/settings.json",
    "app-template/.claude/settings.format-hook.json",
    "app-template-ruby/.claude/cloud-setup.sh",
    "app-template-ruby/.claude/settings.json",
    "app-template-ruby/.claude/settings.format-hook.json"
  ],
  "test_globs": [
    "test/**",
    "**/*_test.py",
    "**/*.test.js",
    "**/*.test.ts",
    "**/*.spec.js",
    "**/*.spec.ts"
  ]
}
```

There is no additional enforcement-file exception. Agent instructions, hook
configuration, data, docs and artifacts are not automatically classified as
source. Existing repository privacy, deployment and domain guidance still applies.
Recommended test commands in repository documentation are guidance, not a command
allowlist. The runner records the authoritative red/green evidence; this role
assignment does not make command execution a special permission.

## Enforcement boundary

The guard checks direct Codex apply_patch edits and Claude Write, Edit and
NotebookEdit operations. It checks all operands of add, update, delete and move.
Native host agent_id and agent_type identify roles; a prompt claim does not.
Allowed or unrelated calls return an empty object and leave native approvals
unchanged. The hook only emits explicit denials for invalid or forbidden direct
edits. Native sandbox and permission settings remain in control of other actions.

Shell commands and MCP tools can modify files without direct-edit interception.
This deliberately narrow hook is not complete filesystem confinement. Do not
use another route to evade the source/test ownership workflow. Review final
diffs and accepted-test hashes, including changes made by formatters, Git hooks,
snapshot updates and other commands. Accidental native hook failure is an
explicitly accepted limitation. There is no separate Git delivery prohibition.

## Bash audit log

Claude and Codex Bash calls are audited, not blocked. Only source and test files, as the
policy classifies them, are examined. Before each call the audit hook snapshots
dirty source and test files; afterwards it compares. When a source or test file
changed, it appends one JSON line to `.agent-audit/bash.jsonl` with the command,
session, agent id, agent type, role (`main` for the parent session), outcome,
HEAD before and after, each changed source or test path with a unified diff
capped at 200 lines, and `violations` for changes the role does not own. Other
files are never read, stored or listed, and calls that change only them are not
logged. Ignored files are not audited. Codex entries include `platform: codex`;
existing Claude entries retain their format. Codex before-call context preserves
the command and agent identity when a completion event omits those fields.

Claude uses PreToolUse, PostToolUse and PostToolUseFailure. Codex uses only
PreToolUse and PostToolUse; a reported integer exit status determines success
or failure, otherwise outcome is `unknown`. No completion event means no
completed audit entry. Audit hooks run synchronously and return an empty object;
they never approve, deny or alter a call, and audit failures do not stop work.

The command is recorded verbatim, so a secret typed into a command that also
changes a source or test file enters the log. Keep secrets out of commands.
Snapshots write the contents of dirty source and test files to the local Git
object store as unreferenced blobs; `git gc` prunes them and they are never
pushed. Pending markers live under `.git/agent-audit/`.
Codex pending markers temporarily store raw commands and agent identity even for
calls that change only noncode files or no files. They do not store other tool
arguments. Completion replaces them with timing-only markers; interrupted calls
can leave command context behind. Stale markers are removed only when a later
tracked call starts after they are 24 hours old, not by a background timer.
Claude pending markers do not add command or identity storage.

An entry records changes observed while the command ran, not proof of who made
them. Claude Write, Edit and NotebookEdit and Codex apply_patch calls are tracked
for timing only. Every tracked call that ran at any moment during the command,
finished or not, is listed in
`overlapping_tool_use_ids`, and `attribution` is `ambiguous` when that list is
not empty, otherwise `exclusive`. An edit that never reports back, such as one
the guard denied, stops counting after 60 seconds. Treat ambiguous violations
as leads to check against the other calls, not findings.

Commit the log with the work. `.gitattributes` uses union merge for it. Reviewers
check `violations` before accepting. These registrations cover native Bash
events, not arbitrary MCP commands or external processes. CLI and desktop audit
activation must each be validated separately; installed files are not evidence
that hooks are trusted or running.

## Platform setup and activation

Codex definitions are in .codex/agents and its hook registration is in
.codex/hooks.json. Review exact new definitions through /hooks when required.
Claude definitions are in .claude/agents and its registration is in
.claude/settings.json. This setup adds no Claude tool allowlists, broad Edit
denials or sandbox overrides. Existing unrelated native settings and hooks are
preserved. No model is selected. Codex roles are workflow_spec_writer,
workflow_implementer, workflow_runner, workflow_reviewer and
workflow_orchestrator; Claude role names use hyphens.

Existing legacy role files remain for reference. Use the workflow roles for
source/test work; an unrecognized identity cannot edit either class. Existing
native protections may independently limit configuration files or other actions.
Codex CLI, Claude Code and desktop require separate native validation. Installing
files does not establish hook trust or runtime validation.

The workflow manifest records generated bytes. Reinstall from the maintained
setup after review and compare hashes for drift. Preserve repository-specific
instructions outside the bounded generated sections.
