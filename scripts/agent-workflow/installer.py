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
AUDIT_ATTRIBUTE = '.agent-audit/*.jsonl merge=union'
BEGIN = '<!-- BEGIN MANAGED AGENT WORKFLOW -->'
END = '<!-- END MANAGED AGENT WORKFLOW -->'
MANIFEST_PATH = '.codex/hooks/workflow-manifest.json'
OPTIONAL_GUIDES = ('.claude/testing.md', '.codex/README.md', '.codex/testing.md',
                   'docs/codex-agents.md', 'docs/agent-guardrails.md')
MANAGED_PATHS = {'AGENTS.md', 'CLAUDE.md', '.docs/agent-workflow.md', '.gitattributes',
                 '.codex/config.toml', '.codex/hooks.json', '.claude/settings.json',
                 MANIFEST_PATH, *OPTIONAL_GUIDES}
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
    return bool(argv[index:index + 1] and argv[index] in scripts)


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
        hooks.setdefault(event, []).append({'matcher': matcher, 'hooks': [
            {'type': 'command', 'command': command, 'timeout': 10}]})


def with_audit_attribute(text):
    if AUDIT_ATTRIBUTE in text.splitlines():
        return text
    return text + ('' if not text or text.endswith('\n') else '\n') + AUDIT_ATTRIBUTE + '\n'


def enable_toml_flag(text, table, key):
    data = tomllib.loads(text)
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
           installer_metadata=None) -> dict:
    """Plan generated bytes and drift without modifying the checkout."""
    root = guard.repository_root(root)
    guard.validate_policy(policy)
    files = {}
    def existing(rel):
        path = safe_destination(root, rel)
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
    codex_config = existing('.codex/config.toml')
    files['.codex/config.toml'] = enable_codex_hooks(codex_config)
    for platform in ('codex', 'claude'):
        prefix = '.' + platform
        files[prefix + '/hooks/workflow_guard.py'] = (BASE / 'workflow_guard.py').read_text()
        files[prefix + '/hooks/workflow_audit.py'] = (BASE / 'workflow_audit.py').read_text()
        files[prefix + '/hooks/policy.json'] = json.dumps(policy, indent=2, sort_keys=True) + '\n'
        if platform == 'claude':
            command, matcher = CLAUDE_COMMAND, CLAUDE_MATCHER
        else:
            command, matcher = CODEX_GUARD_COMMAND, '.*'
        config_path = prefix + ('/hooks.json' if platform == 'codex' else '/settings.json')
        config = read_json(config_path)
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
                        'The orchestrator coordinates delegation for this workflow.')
        if role == 'reviewer':
            instructions += ' Always check and report security advisories, including pre-existing findings, affected and patched versions, and exposure uncertainty; follow the security advisory review in .docs/agent-workflow.md.'
        elif role == 'implementer':
            instructions += ' Apply compatible security upgrades and verify them. Obtain explicit user permission before upgrades requiring significant application changes, API rewrites, migrations, or substantial compatibility work; report unresolved advisories.'
        files[f'.codex/agents/workflow_{role}.toml'] = 'name = ' + json.dumps('workflow_' + role) + '\ndescription = ' + json.dumps(description) + '\ndeveloper_instructions = ' + json.dumps(instructions) + '\n'
        claude_role_path = f'.claude/agents/workflow-{role.replace("_", "-")}.md'
        old_role = existing(claude_role_path)
        description_yaml = json.dumps(description)
        frontmatter = old_role.split('\n---', 1)[0] if old_role.startswith('---\n') else ''
        if re.search(r"^description: '[^\n]*'\s*$", frontmatter, re.MULTILINE):
            description_yaml = "'" + description.replace("'", "''") + "'"
        files[claude_role_path] = '---\nname: workflow-' + role.replace('_', '-') + '\ndescription: ' + description_yaml + '\n---\n\n' + instructions + '\n'
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
