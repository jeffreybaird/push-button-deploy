"""Idempotent renderer for the shared native agent workflow. No host trust edits."""
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import shlex
import stat
import tomllib

BASE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location('_installed_workflow_guard', BASE / 'workflow_guard.py')
guard = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(guard)
CLAUDE_GUARD = '$CLAUDE_PROJECT_DIR/.claude/hooks/workflow_guard.py'
# Resolved by Claude at run time so clones, worktrees and cloud sessions find the guard.
CLAUDE_COMMAND = ('python3 -B "' + CLAUDE_GUARD + '" --platform claude --root "$CLAUDE_PROJECT_DIR" '
                  '--policy "$CLAUDE_PROJECT_DIR/.claude/hooks/policy.json"')
CLAUDE_MATCHER = 'Write|Edit|NotebookEdit'
AUDIT_SCRIPT = '$CLAUDE_PROJECT_DIR/.claude/hooks/workflow_audit.py'
AUDIT_COMMAND = ('python3 -B "' + AUDIT_SCRIPT + '" --root "$CLAUDE_PROJECT_DIR" '
                 '--policy "$CLAUDE_PROJECT_DIR/.claude/hooks/policy.json"')
AUDIT_EVENTS = ('PreToolUse', 'PostToolUse', 'PostToolUseFailure')
AUDIT_MATCHER = 'Bash|Write|Edit|NotebookEdit'
CODEX_AUDIT_ROOT = '$(git rev-parse --show-toplevel)'
CODEX_GUARD_SCRIPT = CODEX_AUDIT_ROOT + '/.codex/hooks/workflow_guard.py'
CODEX_GUARD_COMMAND = ('python3 -B "' + CODEX_GUARD_SCRIPT + '" --platform codex '
                       '--root "' + CODEX_AUDIT_ROOT + '" --policy "' + CODEX_AUDIT_ROOT +
                       '/.codex/hooks/policy.json"')
CODEX_AUDIT_SCRIPT = CODEX_AUDIT_ROOT + '/.codex/hooks/workflow_audit.py'
CODEX_AUDIT_COMMAND = ('python3 -B "' + CODEX_AUDIT_SCRIPT + '" --platform codex '
                       '--root "' + CODEX_AUDIT_ROOT + '" --policy "' + CODEX_AUDIT_ROOT +
                       '/.codex/hooks/policy.json"')
CODEX_DIAGNOSTICS_SCRIPT = CODEX_AUDIT_ROOT + '/.codex/hooks/hook_diagnostics.py'
DIAGNOSTICS_IGNORE = '/.agent-diagnostics/'
AUDIT_ATTRIBUTE = '.agent-audit/*.jsonl merge=union'
BEGIN = '<!-- BEGIN MANAGED AGENT WORKFLOW -->'
END = '<!-- END MANAGED AGENT WORKFLOW -->'
MANIFEST_PATH = '.codex/hooks/workflow-manifest.json'
MODEL_PROFILE_PATH = '.docs/agent-models.json'
MODEL_EFFORTS = {
    'codex': ('model_reasoning_effort', {'none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max', 'ultra'}),
    'claude': ('effort', {'low', 'medium', 'high', 'xhigh', 'max'}),
}
OPTIONAL_GUIDES = ('.claude/testing.md', '.codex/README.md', '.codex/testing.md',
                   'docs/codex-agents.md', 'docs/agent-guardrails.md')
MANAGED_PATHS = {'AGENTS.md', 'CLAUDE.md', '.docs/agent-workflow.md', '.gitattributes',
                 '.codex/config.toml', '.codex/hooks.json', '.claude/settings.json',
                 MANIFEST_PATH, *OPTIONAL_GUIDES}
MANAGED_PATHS.update({'.codex/hooks/hook_diagnostics.py', '.docs/hook-diagnostics.md', '.gitignore'})
for _platform in ('codex', 'claude'):
    MANAGED_PATHS.update('.' + _platform + '/hooks/' + name for name in
                         ('workflow_guard.py', 'workflow_audit.py', 'policy.json'))
for _role in guard.ROLES:
    MANAGED_PATHS.add(f'.codex/agents/workflow_{_role}.toml')
    MANAGED_PATHS.add(f'.claude/agents/workflow-{_role.replace("_", "-")}.md')


def section(text, content):
    separator = '\n\n' if BEGIN + '\n\n' in text else '\n'
    block = BEGIN + separator + content.rstrip() + '\n' + END
    if text.count(BEGIN) != text.count(END) or text.count(BEGIN) > 1:
        raise ValueError('Malformed managed instruction section')
    if BEGIN in text:
        if text.index(BEGIN) > text.index(END):
            raise ValueError('Reversed managed instruction section')
        return text[:text.index(BEGIN)] + block + text[text.index(END) + len(END):]
    return text + ('\n' if text.endswith('\n') else '\n\n') + block + '\n'


def safe_destination(root, rel):
    path = root / rel
    for candidate in [path, *path.parents]:
        if candidate == root.parent:
            break
        try:
            info = candidate.lstat()
        except FileNotFoundError:
            continue
        if stat.S_ISLNK(info.st_mode):
            raise ValueError('Refusing symlink configuration destination: ' + str(candidate))
        if candidate == path and (not stat.S_ISREG(info.st_mode) or info.st_nlink != 1):
            raise ValueError('Destination is not an ordinary file: ' + str(candidate))
        if candidate != path and not stat.S_ISDIR(info.st_mode):
            raise ValueError('Destination parent is not a directory')
    return path


def model_profile(root):
    """Read the optional project-owned profile; reject invalid input before writes."""
    path = safe_destination(root, MODEL_PROFILE_PATH)
    if not path.exists():
        return {}
    data = json.loads(path.read_text())
    if (not isinstance(data, dict) or type(data.get('schema_version')) is not int
            or data['schema_version'] != 1 or set(data) - {'schema_version', 'codex', 'claude'}):
        raise ValueError('Invalid model profile schema')
    for platform in ('codex', 'claude'):
        if platform not in data:
            continue
        settings = data[platform]
        if not isinstance(settings, dict) or set(settings) - {'model', 'roles'}:
            raise ValueError('Invalid model profile platform: ' + platform)
        roles = settings.get('roles', {})
        if not isinstance(roles, dict) or set(roles) - set(guard.ROLES):
            raise ValueError('Invalid model profile roles: ' + platform)
        effort, allowed_efforts = MODEL_EFFORTS[platform]
        for fields in [settings, *roles.values()]:
            keys = {'model', 'roles'} if fields is settings else {'model', effort}
            if not isinstance(fields, dict) or set(fields) - keys:
                raise ValueError('Invalid model profile fields: ' + platform)
            if 'model' in fields and (not isinstance(fields['model'], str) or not fields['model'].strip()):
                raise ValueError('Model must be a nonblank string: ' + platform)
            if effort in fields and (not isinstance(fields[effort], str) or fields[effort] not in allowed_efforts):
                raise ValueError('Invalid model effort: ' + platform)
    return data


def toml_statements(text):
    """Yield statement spans and comment positions without rewriting native TOML."""
    start = index = depth = 0
    quote = None
    triple = False
    comment = None
    while index < len(text):
        char = text[index]
        if quote:
            if quote == '"' and char == '\\':
                index += 2
                continue
            delimiter = quote * (3 if triple else 1)
            if text.startswith(delimiter, index):
                index += len(delimiter)
                if triple:
                    # TOML permits one or two literal quotes immediately before
                    # a multiline string's closing delimiter.
                    while index < len(text) and text[index] == quote:
                        index += 1
                quote = None
                continue
        elif char in ('"', "'"):
            quote = char
            triple = text.startswith(char * 3, index)
            index += 3 if triple else 1
            continue
        elif char == '#':
            comment = index
            newline = text.find('\n', index)
            index = len(text) if newline == -1 else newline
            continue
        elif char in '[{':
            depth += 1
        elif char in ']}':
            depth -= 1
        elif char == '\n' and depth == 0:
            yield start, index + 1, comment
            start, comment = index + 1, None
        index += 1
    if start < len(text):
        yield start, len(text), comment


def overlay_toml_model(text, model):
    """Set only the root model scalar, retaining comments and all other bytes."""
    data = tomllib.loads(text)
    if data.get('model') == model:
        return text
    value = json.dumps(model, ensure_ascii=False)
    insertion = len(text)
    for start, end, comment in toml_statements(text):
        statement = text[start:end]
        if statement.lstrip().startswith('['):
            insertion = start
            break
        match = re.match(r'''(\s*(?:model|"model"|'model')\s*=\s*)''', statement)
        if match:
            suffix = text[comment:end] if comment is not None else ('\n' if statement.endswith('\n') else '')
            if comment is not None:
                suffix = ' ' + suffix
            result = text[:start] + match[1] + value + suffix + text[end:]
            tomllib.loads(result)
            return result
    if 'model' in data:
        raise ValueError('Nonstandard root model needs manual migration')
    prefix = text[:insertion]
    result = prefix + ('' if not prefix or prefix.endswith('\n') else '\n') + 'model = ' + value + '\n' + text[insertion:]
    tomllib.loads(result)
    return result


def merge_hooks(data, command, matcher, root, platform, legacy_commands):
    hooks = data.setdefault('hooks', {})
    if not isinstance(hooks, dict):
        raise ValueError('Invalid hooks configuration')
    own_paths = {str(root / ('.' + platform) / 'hooks/workflow_guard.py')}
    if platform == 'claude':
        own_paths.add(CLAUDE_GUARD)
    else:
        own_paths.add(CODEX_GUARD_SCRIPT)
    legacy = set(legacy_commands)
    legacy.update({'bash "$CLAUDE_PROJECT_DIR/.claude/hooks/protect-tests.sh"',
                   './scripts/protect-tests.sh'})
    for event, registrations in list(hooks.items()):
        if not isinstance(registrations, list):
            raise ValueError('Invalid hook registrations')
        kept = []
        for registration in registrations:
            if not isinstance(registration, dict):
                raise ValueError('Invalid hook registration object')
            registered_hooks = registration.get('hooks', [])
            if not isinstance(registered_hooks, list):
                raise ValueError('Invalid registration hooks list')
            copy = dict(registration)
            retained = []
            for hook in registered_hooks:
                if not isinstance(hook, dict):
                    raise ValueError('Invalid hook object')
                cmd = hook.get('command', '')
                if not isinstance(cmd, str):
                    raise ValueError('Invalid hook command')
                try:
                    argv = shlex.split(cmd)
                except ValueError:
                    argv = []
                own_execution = (managed_audit_command(cmd, own_paths) if platform == 'codex'
                                 else own_paths.intersection(argv))
                managed = (own_execution and '--platform' in argv and
                           argv[argv.index('--platform') + 1:argv.index('--platform') + 2] == [platform])
                if cmd not in legacy and not managed:
                    retained.append(hook)
            if retained:
                copy['hooks'] = retained
                kept.append(copy)
        hooks[event] = kept
    hooks.setdefault('PreToolUse', []).append({'matcher': matcher, 'hooks': [
        {'type': 'command', 'command': command, 'timeout': 5}]})


def managed_audit_command(command, scripts):
    """Recognize execution of our script, never its appearance as command data."""
    try:
        argv = shlex.split(command)
    except ValueError:
        return False
    if not argv:
        return False
    if argv[0] in scripts:
        return True
    if Path(argv[0]).name not in ('python', 'python3'):
        return False
    index = 2 if argv[1:2] == ['-B'] else 1
    if argv[index:index + 1] and argv[index] in {
            CODEX_DIAGNOSTICS_SCRIPT,
            *(str(Path(script).with_name('hook_diagnostics.py')) for script in scripts
              if not script.startswith('$'))}:
        options = argv[index + 1:]
        if '--' not in options:
            return False
        separator = options.index('--')
        prefix = options[:separator]
        if (len(prefix) != 6 or prefix[::2] != ['--hook', '--event', '--root'] or
                prefix[1] not in ('workflow_guard', 'workflow_audit') or
                prefix[3] not in ('PreToolUse', 'PostToolUse')):
            return False
        return managed_audit_command(shlex.join(options[separator + 1:]), scripts)
    return bool(argv[index:index + 1] and argv[index] in scripts)


def diagnostics_command(command, hook, event):
    return ('python3 -B "' + CODEX_DIAGNOSTICS_SCRIPT + '" --hook ' + hook +
            ' --event ' + event + ' --root "' + CODEX_AUDIT_ROOT + '" -- ' + command)


def merge_audit_hooks(data, platform='claude', root=None):
    """Replace managed audit registrations; leave every other hook untouched."""
    hooks = data.setdefault('hooks', {})
    if platform == 'codex':
        script, command = CODEX_AUDIT_SCRIPT, CODEX_AUDIT_COMMAND
        events, matcher = ('PreToolUse', 'PostToolUse'), '^(Bash|apply_patch)$'
    else:
        script, command = AUDIT_SCRIPT, AUDIT_COMMAND
        events, matcher = AUDIT_EVENTS, AUDIT_MATCHER
    scripts = {script}
    if root is not None:
        scripts.add(str(root / ('.' + platform) / 'hooks/workflow_audit.py'))
    for event in list(hooks):
        kept = []
        for registration in hooks[event]:
            retained = [hook for hook in registration.get('hooks', [])
                        if not managed_audit_command(hook.get('command', ''), scripts)]
            if retained:
                kept.append({**registration, 'hooks': retained})
        hooks[event] = kept
    for event in events:
        registered_command = (diagnostics_command(command, 'workflow_audit', event)
                              if platform == 'codex' else command)
        hooks.setdefault(event, []).append({'matcher': matcher, 'hooks': [
            {'type': 'command', 'command': registered_command, 'timeout': 10}]})


def with_audit_attribute(text):
    if AUDIT_ATTRIBUTE in text.splitlines():
        return text
    return text + ('' if not text or text.endswith('\n') else '\n') + AUDIT_ATTRIBUTE + '\n'


def enable_toml_flag(text, table, key):
    data = tomllib.loads(text)
    if not isinstance(data.get(table, {}), dict):
        raise ValueError('Invalid TOML table: ' + table)
    if data.get(table, {}).get(key) is True:
        return text
    lines = text.splitlines(keepends=True)
    start = next((i for i, line in enumerate(lines) if re.match(r'^\s*\[' + re.escape(table) + r'\]\s*(?:#.*)?$', line.strip())), None)
    if start is None:
        if table in data:
            raise ValueError('Nonstandard table needs manual migration: ' + table)
        return text.rstrip() + '\n\n[' + table + ']\n' + key + ' = true\n'
    end = next((i for i in range(start + 1, len(lines)) if lines[i].lstrip().startswith('[')), len(lines))
    for i in range(start + 1, end):
        if re.match(r'^\s*' + re.escape(key) + r'\s*=', lines[i]):
            lines[i] = key + ' = true\n'
            break
    else:
        lines.insert(start + 1, key + ' = true\n')
    result = ''.join(lines)
    tomllib.loads(result)
    return result


def enable_codex_hooks(text):
    return enable_toml_flag(enable_toml_flag(text, 'features', 'hooks'), 'agents', 'enabled')


def guide(policy):
    return f'''# Agent workflow — version {guard.VERSION}

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

## Coordination and evidence

By default, use one main orchestrator for a single change and reuse existing
role agents for revisions and follow-up work. Assign bounded work through the
pipeline above; add coordination layers only when the task needs them.

Use compact handoffs containing expected behavior, owned paths, relevant
repository guidance, accepted-test hashes when available, validation commands,
and evidence paths. Include explicit task context sufficient to do the assigned
work without reconstructing the conversation. In Codex, use bounded context;
avoid full-history forks by default. Use a full-history fork only when needed
for context that cannot be conveyed reliably in the handoff. Follow native
tool and user rules when selecting context or delegating.

For example, an implementation handoff can be:

> Behavior: reject an expired token, accept a valid token. Own `src/tokens.py`;
> do not edit tests. Guidance: `.docs/project-guidance.md` and this workflow.
> Accepted tests: `test/test_tokens.py`, SHA-256 recorded in
> `/tmp/token-change/accepted.sha256`. Validate: `python3 -m unittest
> discover -s test`. Red evidence: `/tmp/token-change/red.log`; save green
> evidence to `/tmp/token-change/green.log`. Report completion, blockers, or
> material findings with evidence paths.

Return only completion, blockers, and material findings to the coordinator;
omit routine progress narration and repeated status messages. Preserve full
evidence in files or artifacts, including commands, output, failures, skips,
and pending cases. Compact reports are pointers, not substitutes: the
independent reviewer must read the full evidence and inspect the final diff.
Retain the existing PR evidence and full quality gates below.

Use event-driven waits for delegated work where supported. After dispatch,
wait for completion or a material event instead of repeatedly polling unchanged
status or messaging agents for updates. Respect native tool wait limits and
user communication rules; answer user status requests and report real blockers
or material findings promptly. These exceptions do not require routine agent
status chatter or reduce the saved evidence.

## Pull request test evidence

Every PR description must include relevant Ruby Cucumber or Elixir Cucumberex
feature/scenario specifications for its changes. Identify feature paths and
scenario names, and include readable Gherkin, scenario/spec content, or actual
executed scenario output. Names or links alone are insufficient; a generic
test-passed summary does not show the behavior covered.

For Ruby, run `bundle exec rspec <relevant spec paths> --format documentation`
and include the actual command, documentation output and results. Cucumber
scenario output comes from `bundle exec cucumber --format pretty --strict`.
For Elixir, run `mix test <relevant test paths> --trace` for focused ExUnit output
and `MIX_ENV=test mix cucumber --format pretty --strict` for Cucumberex output.
Use paths relevant to the included changes. Report failures, skipped and pending
examples honestly. Never fabricate output or claim an unrun check passed. Long
output may use expandable details blocks while keeping the result visible.

Use `N/A` with an explicit reason for unrelated ecosystems or changes, and
include the actual relevant checks instead. Mandatory tooling missing from a
fresh generated project is a defect, not N/A. Fresh Rails and Sinatra projects
require RSpec and Cucumber; fresh Phoenix, escript and Mix library projects
require ExUnit and Cucumberex. Do not install an unrelated framework solely to
produce PR evidence. Existing applications retain their explicit legacy gates
until their acceptance tooling is adopted; report that limitation honestly.
Focused evidence does not replace required full quality gates: retain normal
full RSpec or `mix test` execution and record all required commands and results.

## Dead-code review

Every PR must include a dead-code review. Check references and dynamic,
configuration, framework, and public entry points before deciding code is unused.
Account for external public API consumers. Test-only references do not prove code
is live or dead. Grep absence alone does not prove code is unused; verify the
usage paths and retain code when its use is uncertain.

Delete confirmed dead code. Propose removing tests that exclusively exercise the
removed behavior. Present a concrete unapplied diff with test file paths and
deletion hunks, and explain why each proposed test removal is obsolete. Obtain
explicit user approval before deleting tests. Reviewer approval does not
substitute for user approval. Keep tests unchanged while approval is pending.
Preserve or adapt tests for live behavior, including mixed coverage. Never delete
failing tests merely to make the suite pass.

Approval preserves source/test role ownership and hook restrictions. The
implementer removes source, the spec writer removes or adapts tests, and the
reviewer approves the changed test contract before implementation. After user
approval, the spec writer applies only the approved test-removal patch when
permitted. If deletion remains blocked, present the exact patch and blocker for
the user to resolve. Never use an alternate editing route or bypass hooks. Do not
bypass the accepted-test contract or weaken assertions to justify removal.

Source cleanup may proceed while test-removal approval is pending. Run the
affected test suite after cleanup. Do not claim green tests or commit cleanup
that leaves tests failing; do not commit incomplete cleanup. The PR description
must record the removed code and tests, or state that no dead code was found.
Record any test-removal patch still awaiting user approval or blocked by hooks.

## Elixir doctests

For Elixir projects, doctests must demonstrate meaningful use of the function with
representative valid inputs and assert its intended result. Include at least one
happy-path example; nil, empty-input, fallback, or error examples alone are
insufficient. For predicates, include an input that satisfies the predicate. For
time-dependent predicates, show valid inputs on both sides of the time condition,
using a stable clock or generous relative offsets to avoid brittle date-dependent
examples. Keep useful edge cases as additional examples, not substitutes for the
happy path.

Inventory `@doc` and `@moduledoc` `iex>` examples across the project. Ensure every
module containing doctests is registered with `doctest` in ExUnit. Run all doctests
through the normal `mix test` suite, including CI; do not leave registrations
skipped, excluded, filtered out, or confined to a separate command. Verify actual
execution of all doctests in the normal suite; registration alone is insufficient.

Verify the module is registered with `doctest` in an ExUnit test and run those
tests. An `iex>` block alone does not make an example execute. Review examples
by asking whether an implementation that always returns the fallback value would
still pass; if so, add an example exercising the intended behavior. Follow project
rules for functions requiring database or external-service setup; cover their
successful behavior with appropriate tests rather than token fallback doctests.

## Security advisory review

Every agent review must check and explicitly report security advisories, including
pre-existing findings unrelated to the current diff. Use the project's dependency
security audit with current advisory data where available; record the command,
result, and any unavailable audit or stale data rather than claiming a clean scan.
For each finding, report the advisory identifier, affected dependency and installed
version, patched versions, and known exposure conditions or uncertainty.

Route findings to the implementer. Apply available compatible security upgrades
and rerun the relevant tests and security audit. Before an upgrade that requires
significant application changes (such as broad API rewrites, data migrations, or
substantial compatibility work), explain the required changes and obtain explicit
user permission. If no compatible fix is available, report the remaining advisory
and options. Do not suppress advisories, weaken checks, or silently accept the risk.

## Committing

Make small, focused, atomic commits. Each commit has one coherent purpose and
contains the smallest complete logical next step that leaves the project in a
working state. It must be independently reviewable and reversible. Stage only
the files and changes relevant to that purpose; preserve unrelated work.
Commit each complete logical step rather than waiting to combine several steps
into one large feature commit.

Tests must be green before every commit, and all required project checks still
apply. Keep the TDD red phase local until the accepted tests and the implementation
needed to satisfy them pass together. Do not commit failing tests, incomplete
implementation or WIP. Do not bundle unrelated work into one commit or split a
logical change into commits that leave broken intermediate states.

## Precommit corrections

For Elixir projects, run `mix format --force` before the remaining precommit
checks. For Ruby projects using RuboCop, run `bundle exec rubocop --autocorrect`
first, then recheck the corrected result. Correctable offenses are not a reason
to stop before attempting safe autocorrection; unresolved lint offenses block the
commit. Do not use `--autocorrect-all`, disable cops, or weaken lint rules to pass.
Other required test, audit, and verification failures still block completion.
CI may retain read-only formatting and lint checks.

Formatters and autocorrectors can edit both source and tests. Preserve role
ownership: the implementer corrects source; the spec writer corrects tests.
Partition correction commands by owned paths where needed. The reviewer must
verify that test corrections preserve the accepted contract; refresh test hashes
only after that review, then have the runner rerun the relevant checks. A changed
hash is not permission to weaken an assertion or change expected behavior.
The runner uses equivalent read-only checks rather than invoking a precommit
alias that performs corrections; source and test owners complete corrections first.

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
{json.dumps(policy, indent=2, sort_keys=True)}
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

### Optional project model profile

An optional project-owned profile at `.docs/agent-models.json` selects native
main and workflow role models. Its `schema_version` is `1`. The optional
`codex` and `claude` objects each accept `model` and `roles`; role keys are
`spec_writer`, `implementer`, `runner`, `reviewer`, and `orchestrator`.
Each role accepts `model`, plus `model_reasoning_effort` for Codex or `effort`
for Claude. Model identifiers must be nonblank strings; the host validates
availability and model-specific effort support. Codex effort values are
`none`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max`, `ultra`; Claude
effort values are `low`, `medium`, `high`, `xhigh`, `max`. Main effort settings
remain native settings rather than profile fields.

For example: `{{"schema_version": 1, "codex": {{"model": "gpt-6.1-sol",
"roles": {{"runner": {{"model": "gpt-6-luna", "model_reasoning_effort": "low"}}}}}}}}`.

Preview and apply through the maintained updater. The profile is never
generated, rewritten, or included in generated manifests. Invalid profiles
and unsafe filesystem paths block writes. Without a profile, native main
settings are preserved and generated roles inherit. Removing a main model
from the profile preserves the current native main model; change that native
setting explicitly to change the selection. Removing a role override restores
inheritance for that field at the next update. Hooks, policy, and role
instruction bodies are unchanged by model selection.

Codex definitions are in .codex/agents and its hook registration is in
.codex/hooks.json. Review exact new definitions through /hooks when required.
Claude definitions are in .claude/agents and its registration is in
.claude/settings.json. This setup adds no Claude tool allowlists, broad Edit
denials or sandbox overrides. Existing unrelated native settings and hooks are
preserved. No model is selected by default; the optional profile above makes
explicit project selections. Codex roles are workflow_spec_writer,
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
'''


V1_EDIT_DENIES = ['Edit(/' + path + ')' for path in (
    '.claude/**', '.codex/**', '**/.claude/**', '**/.codex/**', '.git/**',
    '**/.git/**', 'AGENTS.md', 'CLAUDE.md', '**/AGENTS.md', '**/CLAUDE.md',
    '.docs/agent-workflow.md', '**/.docs/agent-workflow.md')]


def remove_v1_restrictions(config, baseline):
    """Remove only known v1 additions with an explicit pre-install baseline."""
    if not isinstance(baseline, dict):
        raise ValueError('Previous Claude settings must be an object')
    permissions = config.get('permissions')
    old_permissions = baseline.get('permissions', {})
    if isinstance(permissions, dict) and isinstance(old_permissions, dict):
        original = old_permissions.get('deny', [])
        if isinstance(permissions.get('deny'), list) and isinstance(original, list):
            permissions['deny'] = [rule for rule in permissions['deny']
                                   if rule not in V1_EDIT_DENIES or rule in original]
            if not permissions['deny'] and 'deny' not in old_permissions:
                del permissions['deny']
        if not permissions and 'permissions' not in baseline:
            del config['permissions']
    sandbox = config.get('sandbox')
    old_sandbox = baseline.get('sandbox', {})
    if isinstance(sandbox, dict) and isinstance(old_sandbox, dict):
        for key, installed in (('enabled', True), ('allowUnsandboxedCommands', False)):
            if key in sandbox and sandbox[key] is installed:
                if key in old_sandbox:
                    sandbox[key] = old_sandbox[key]
                else:
                    del sandbox[key]
        if not sandbox and 'sandbox' not in baseline:
            del config['sandbox']


def render(root: Path, policy: dict, *, previous_claude_settings=None,
           installer_metadata=None, existing_files=None) -> dict:
    """Plan generated bytes and drift without modifying the checkout."""
    if root.exists():
        root = guard.repository_root(root)
    elif not root.is_absolute():
        raise ValueError('Repository root must be absolute')
    guard.validate_policy(policy)
    profile = model_profile(root)
    files = {}
    def existing(rel):
        path = safe_destination(root, rel)
        if existing_files is not None and rel in existing_files:
            return existing_files[rel]
        return path.read_text() if path.exists() else ''
    def read_json(rel):
        text = existing(rel)
        value = json.loads(text) if text else {}
        if not isinstance(value, dict):
            raise ValueError('Configuration must be an object: ' + rel)
        return value
    old_manifest = read_json(MANIFEST_PATH)
    if (root / MANIFEST_PATH).exists():
        hashes = old_manifest.get('sha256')
        if not isinstance(hashes, dict):
            raise ValueError('Invalid manifest sha256 mapping')
        for rel, digest in hashes.items():
            if rel not in MANAGED_PATHS or rel == MANIFEST_PATH:
                raise ValueError('Unknown or unsafe manifest path: ' + str(rel))
            if not isinstance(digest, str) or not re.fullmatch('[0-9a-f]{64}', digest):
                raise ValueError('Invalid manifest digest: ' + rel)
            safe_destination(root, rel)
    summary = f'''Shared native agent workflow version {guard.VERSION} applies to every behavior
change. This section supersedes legacy workflow, role-assignment, and blanket
test-edit approval instructions only. Preserve domain, privacy, coverage,
static-analysis, deployment, and project constraints. Follow [.docs/agent-workflow.md](.docs/agent-workflow.md) for role ownership,
red → accepted tests → implementation → green → independent review.
Accepted tests are a contract: only the test writer changes them when the
expected behavior changes, with renewed review. Never weaken tests to pass.
The orchestrator coordinates the pipeline. This hook restricts only direct source
and test edits; other files, tools and commands retain ordinary native permissions.
Do not use alternate editing routes to evade the source/test ownership workflow.'''
    for name in ('AGENTS.md', 'CLAUDE.md'):
        files[name] = section(existing(name), summary)
    files['.docs/agent-workflow.md'] = guide(policy)
    for name in OPTIONAL_GUIDES:
        old = existing(name)
        if old:
            files[name] = section(old, summary)
    files['.gitattributes'] = with_audit_attribute(existing('.gitattributes'))
    ignore = existing('.gitignore')
    files['.gitignore'] = (ignore if DIAGNOSTICS_IGNORE in ignore.splitlines() else
                           ignore + ('' if not ignore or ignore.endswith('\n') else '\n') +
                           DIAGNOSTICS_IGNORE + '\n')
    files['.codex/hooks/hook_diagnostics.py'] = (BASE / 'hook_diagnostics.py').read_text()
    files['.docs/hook-diagnostics.md'] = (BASE / 'hook-diagnostics.md').read_text()
    codex_config = existing('.codex/config.toml')
    files['.codex/config.toml'] = enable_codex_hooks(codex_config)
    if 'model' in profile.get('codex', {}):
        files['.codex/config.toml'] = overlay_toml_model(files['.codex/config.toml'], profile['codex']['model'])
    for platform in ('codex', 'claude'):
        prefix = '.' + platform
        files[prefix + '/hooks/workflow_guard.py'] = (BASE / 'workflow_guard.py').read_text()
        files[prefix + '/hooks/workflow_audit.py'] = (BASE / 'workflow_audit.py').read_text()
        files[prefix + '/hooks/policy.json'] = json.dumps(policy, indent=2, sort_keys=True) + '\n'
        if platform == 'claude':
            command, matcher = CLAUDE_COMMAND, CLAUDE_MATCHER
        else:
            command, matcher = diagnostics_command(CODEX_GUARD_COMMAND, 'workflow_guard', 'PreToolUse'), '.*'
        config_path = prefix + ('/hooks.json' if platform == 'codex' else '/settings.json')
        config = read_json(config_path)
        if platform == 'claude' and 'model' in profile.get(platform, {}):
            config['model'] = profile[platform]['model']
        merge_hooks(config, command, matcher, root, platform, policy.get('legacy_commands', []))
        if (platform == 'claude' and previous_claude_settings is not None
                and old_manifest.get('version') == '1.0.0'):
            remove_v1_restrictions(config, previous_claude_settings)
        merge_audit_hooks(config, platform, root)
        files[config_path] = json.dumps(config, indent=2, sort_keys=True) + '\n'
    responsibilities = {
        'spec_writer': 'Own test and test-fixture edits. Do not edit source. Define expected behavior for reviewer acceptance.',
        'implementer': 'Own source edits. Do not edit tests. Accepted tests are frozen contracts; report discrepancies rather than weakening them.',
        'runner': 'Record authoritative red and green test evidence. Do not edit source or tests.',
        'reviewer': 'Review tests before implementation and independently review the implementation and final diff. Do not edit source or tests.',
        'orchestrator': 'Coordinate the mandatory pipeline and assign bounded work. Do not edit source or tests.'}
    for role in guard.ROLES:
        description = responsibilities[role]
        instructions = (description + ' Read .docs/agent-workflow.md and repository guidance. '
                        'Noncode edits and commands retain ordinary native permissions. '
                        'The orchestrator coordinates delegation for this workflow. '
                        'Use compact handoffs with expected behavior, owned paths, relevant repository guidance, '
                        'accepted-test hashes when available, validation commands, and evidence paths. '
                        'Return only completion, blockers, and material findings; follow the coordination and evidence guidance in .docs/agent-workflow.md.')
        if role in ('runner', 'reviewer'):
            instructions += ' Preserve full evidence in files or artifacts. The independent reviewer must read the full evidence and inspect the final diff.'
        if role == 'orchestrator':
            instructions += ' By default, use one main orchestrator for a single change and reuse existing role agents.'
        if role == 'reviewer':
            instructions += ' Always check and report security advisories, including pre-existing findings, affected and patched versions, and exposure uncertainty; follow the security advisory review in .docs/agent-workflow.md.'
            instructions += ' Every PR must include a dead-code review; verify confirmed-unused evidence, source and test removal ownership, retained live-behavior coverage, and the PR report under .docs/agent-workflow.md#dead-code-review. Obtain explicit user approval before deleting tests; reviewer acceptance is not user approval. Review the concrete unapplied test-removal patch, preserve tests while approval is pending, and verify that only the approved patch is applied by the spec writer when permitted. Report the exact patch and blocker if hooks prevent deletion; never bypass them.'
            instructions += ' Every PR must include relevant Ruby Cucumber or Elixir Cucumberex scenario content or executed scenario output, plus actual Ruby RSpec --format documentation or Elixir ExUnit --trace output with commands and results; verify honest failures, skipped and pending examples, reasoned N/A only for unrelated ecosystems or changes, and completion of required full quality gates under .docs/agent-workflow.md#pull-request-test-evidence. Mandatory tooling missing from a fresh generated project is a defect, not N/A. Names or links alone are insufficient acceptance evidence. Never accept fabricated output.'
        elif role == 'implementer':
            instructions += ' Apply compatible security upgrades and verify them. Obtain explicit user permission before upgrades requiring significant application changes, API rewrites, migrations, or substantial compatibility work; report unresolved advisories.'
        codex_instructions = instructions
        if role == 'orchestrator':
            codex_instructions += ' Use bounded context with explicit task context; avoid full-history forks by default. Use a full-history fork only when needed to convey context reliably, respecting native tool and user rules.'
        files[f'.codex/agents/workflow_{role}.toml'] = 'name = ' + json.dumps('workflow_' + role) + '\ndescription = ' + json.dumps(description) + '\ndeveloper_instructions = ' + json.dumps(codex_instructions) + '\n'
        for key, value in profile.get('codex', {}).get('roles', {}).get(role, {}).items():
            files[f'.codex/agents/workflow_{role}.toml'] += key + ' = ' + json.dumps(value, ensure_ascii=False) + '\n'
        claude_role_path = f'.claude/agents/workflow-{role.replace("_", "-")}.md'
        old_role = existing(claude_role_path)
        description_yaml = json.dumps(description)
        frontmatter = old_role.split('\n---', 1)[0] if old_role.startswith('---\n') else ''
        if re.search(r"^description: '[^\n]*'\s*$", frontmatter, re.MULTILINE):
            description_yaml = "'" + description.replace("'", "''") + "'"
        model_fields = ''.join(key + ': ' + json.dumps(value, ensure_ascii=False) + '\n'
                               for key, value in profile.get('claude', {}).get('roles', {}).get(role, {}).items())
        files[claude_role_path] = '---\nname: workflow-' + role.replace('_', '-') + '\ndescription: ' + description_yaml + '\n' + model_fields + '---\n\n' + instructions + '\n'
    hashes = {rel: hashlib.sha256(content.encode()).hexdigest() for rel, content in files.items()}
    manifest = {'version': guard.VERSION, 'sha256': hashes}
    metadata = installer_metadata if installer_metadata is not None else old_manifest.get('installer')
    if metadata is not None:
        manifest['installer'] = metadata
    drift = [rel for rel, digest in old_manifest.get('sha256', {}).items()
             if not (root / rel).exists() or hashlib.sha256((root / rel).read_bytes()).hexdigest() != digest]
    files[MANIFEST_PATH] = json.dumps(manifest, indent=2, sort_keys=True) + '\n'
    # Complete validation before the first mutation.
    for rel in files:
        safe_destination(root, rel)
    report = {'version': guard.VERSION, 'files': sorted(files), 'previous_drift': drift,
              'native_validation': 'NOT_RUN', 'hook_trust': 'USER_REVIEW_REQUIRED'}
    return {'files': files, 'report': report}


def install(root: Path, policy: dict, *, previous_claude_settings=None,
            installer_metadata=None) -> dict:
    """Write a fully validated plan; callers needing a preview should use render."""
    root = guard.repository_root(root)
    plan = render(root, policy, previous_claude_settings=previous_claude_settings,
                  installer_metadata=installer_metadata)
    for rel, content in plan['files'].items():
        path = root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
    return plan['report']
