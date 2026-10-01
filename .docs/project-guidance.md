# push-button-deploy: shared project guidance

This is the canonical project guidance for both Codex and Claude. Read it before
working in this repository. `AGENTS.md` and `CLAUDE.md` are equivalent entry points;
maintain project rules here rather than duplicating them in those files.

Read [the agent workflow](agent-workflow.md) for every behavior change. It owns
role assignments, test-contract review, and enforcement limits, and supersedes
legacy workflow instructions in supporting documents. Project domain, privacy,
coverage, static-analysis, deployment, and release constraints still apply.
Project-specific rules take precedence over generic framework/template examples;
examples do not authorize new features or infrastructure.

Paths in backticks are relative to the repository root. Supporting guidance in
`.claude/`, `.codex/`, and `docs/` applies to both platforms when relevant, regardless
of the directory name. Read the referenced guidance for the area being changed.
Read any directory-specific `AGENTS.md` or `CLAUDE.md` before working in that
directory; its project rules apply to both platforms. Native tool names, model
choices, slash commands, and hook settings remain platform-specific: use the
documented procedure with your platform's tools, not another platform's commands.

Before committing, follow the correction and security-review requirements in
[the shared agent workflow](agent-workflow.md#precommit-corrections).

# Project rules

Read `README.md` and the relevant `docs/` before changing bootstrap or deployment
behavior. This repository supports multiple frameworks and app types; preserve
the selected framework's conventions rather than importing another template's
assumptions. Files under `app-template*/` are generated-project templates, not
repository-wide instructions. Read their local guidance when editing a template.
