"""Role ownership of direct source/test edits; other tools remain native-controlled."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[2] / 'scripts' / 'agent-workflow' / 'workflow_guard.py'
spec = importlib.util.spec_from_file_location('workflow_guard', SOURCE)
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)
ROLES = ('spec_writer', 'implementer', 'runner', 'reviewer', 'orchestrator')

class GuardContract(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve() / 'repo'
        self.root.mkdir()
        for folder in ('src', 'tests', 'test', 'spec', 'features', 'fixtures', '.docs', 'notes', '.codex/hooks', '.claude/hooks'):
            (self.root / folder).mkdir(parents=True, exist_ok=True)
        self.policy = {'schema_version': 2, 'source_globs': ['src/**', 'app.py'],
                       'test_globs': ['tests/**', 'test/**', 'spec/**', 'features/**', 'fixtures/**', '**/*_test.py', '**/*.test.js']}

    def event(self, role, tool, payload):
        e = {'hook_event_name': 'PreToolUse', 'cwd': str(self.root), 'tool_name': tool, 'tool_input': payload}
        if role is not None:
            e.update(agent_id='child-17', agent_type='workflow_' + role)
        return e

    def check(self, expected, platform, event, policy=None):
        result = guard.evaluate_event(platform, event, str(self.root), self.policy if policy is None else policy)
        if expected == 'allow':
            self.assertEqual({}, result, 'Allowed operations must not override native permissions')
            return
        output = result['hookSpecificOutput']
        self.assertEqual('PreToolUse', output['hookEventName'])
        self.assertEqual(expected, output['permissionDecision'], result)
        self.assertIsInstance(output['permissionDecisionReason'], str)
        self.assertTrue(output['permissionDecisionReason'].strip())

    def edit(self, role, path, platform='codex'):
        if platform == 'codex':
            return self.event(role, 'apply_patch', {'command': f'*** Begin Patch\n*** Add File: {path}\n+contract\n*** End Patch'})
        return self.event(role, 'Write', {'file_path': path, 'content': 'contract'})

    def test_source_and_test_ownership_matrix_both_platforms(self):
        for platform in ('codex', 'claude'):
            for role in (*ROLES, None, 'unknown'):
                for path, owner in [('tests/new.py', 'spec_writer'), ('src/new.py', 'implementer')]:
                    with self.subTest(platform=platform, role=role, path=path):
                        self.check('allow' if role == owner else 'deny', platform, self.edit(role, path, platform))
        self.assertFalse((self.root / 'src/new.py').exists())

    def test_test_layouts_and_colocated_tests_take_precedence(self):
        for path in ('test/unit.py', 'spec/login_spec.rb', 'features/login.feature', 'fixtures/login.json', 'src/foo_test.py', 'src/foo.test.js'):
            for platform in ('codex', 'claude'):
                self.check('allow', platform, self.edit('spec_writer', path, platform))
                self.check('deny', platform, self.edit('implementer', path, platform))

    def test_unscoped_files_allowed_for_every_identity(self):
        for role in (*ROLES, None, 'unknown'):
            for path in ('README.md', 'AGENTS.md', 'CLAUDE.md', '.docs/agent-workflow.md', '.agent-artifacts/run.log', 'data/measurements.csv', '.git/config', '.claude/notes.txt', '.codex/notes.txt', '.codex/hooks/workflow_guard.py', '.claude/hooks/policy.json', '.claude/settings.json'):
                for platform in ('codex', 'claude'):
                    with self.subTest(role=role, path=path, platform=platform):
                        self.check('allow', platform, self.edit(role, path, platform))

    def test_obsolete_command_delivery_and_protected_metadata_have_no_authority(self):
        policy = dict(self.policy, protected_globs=['data/**', 'src/**'], artifact_roots=['.agent-artifacts'], test_commands=[], delivery_enabled=False)
        for platform in ('codex', 'claude'):
            self.check('allow', platform, self.edit('reviewer', 'data/a.csv', platform), policy)
            self.check('allow', platform, self.edit('implementer', 'src/a.py', platform), policy)
            self.check('deny', platform, self.edit('implementer', 'tests/a.py', platform), policy)
            self.check('allow', platform, self.event('runner', 'Bash', {'command': 'git push origin task'}), policy)

    def test_identity_normalization_and_untrusted_claims(self):
        for name in ('spec_writer', 'spec-writer', 'workflow_spec_writer', 'workflow-spec-writer'):
            e = self.edit('spec_writer', 'tests/a.py'); e['agent_type'] = name
            self.check('allow', 'codex', e)
        for identity in ({}, {'agent_id': 'x'}, {'agent_type': 'spec_writer'}, {'agent_id': '', 'agent_type': 'spec_writer'}, {'agent_id': 'x', 'agent_type': 'unknown'}):
            for path, expected in [('tests/a.py', 'deny'), ('src/a.py', 'deny'), ('notes/a.txt', 'allow')]:
                e = self.edit(None, path); e.update(identity); e['tool_input']['agent_type'] = 'spec_writer'
                self.check(expected, 'codex', e)

    def test_claude_edit_and_notebook_paths(self):
        for tool, key, path in [('Edit', 'file_path', 'tests/a.py'), ('NotebookEdit', 'notebook_path', 'tests/a.ipynb')]:
            payload = {key: str(self.root / path), 'old_string': 'a', 'new_string': 'b', 'new_source': 'b'}
            self.check('allow', 'claude', self.event('spec_writer', tool, payload))
            self.check('deny', 'claude', self.event('implementer', tool, payload))
        self.check('deny', 'claude', self.event('implementer', 'Edit', {'path': 'src/a.py'}))

    def test_add_update_delete_move_all_operands(self):
        for operation in ('*** Delete File: tests/a.py', '*** Update File: tests/a.py\n@@\n-old\n+new', '*** Update File: tests/a.py\n*** Move to: tests/b.py\n@@\n-old\n+new'):
            self.check('allow', 'codex', self.event('spec_writer', 'apply_patch', {'command': '*** Begin Patch\n' + operation + '\n*** End Patch'}))
        for role, operation in [('spec_writer', '*** Update File: tests/a.py\n*** Move to: src/a.py\n@@\n-old\n+new'), ('spec_writer', '*** Add File: tests/a.py\n+x\n*** Delete File: src/a.py'), ('implementer', '*** Update File: src/a.py\n*** Move to: tests/a.py\n@@\n-old\n+new'), ('reviewer', '*** Update File: notes/a.txt\n*** Move to: src/a.py\n@@\n-old\n+new')]:
            self.check('deny', 'codex', self.event(role, 'apply_patch', {'command': '*** Begin Patch\n' + operation + '\n*** End Patch'}))

    def test_malformed_direct_edits_deny(self):
        for payload in ({'patch': '*** Begin Patch\n*** Delete File: tests/a\n*** End Patch'}, {'command': ''}, {'command': '*** Begin Patch\n*** End Patch'}, {'command': '*** Begin Patch\n*** Add File: tests/a\n*** End Patch'}, {'command': '*** Begin Patch\n*** Delete File: tests/a\n*** End Patch\njunk'}):
            self.check('deny', 'codex', self.event('spec_writer', 'apply_patch', payload))

    def test_scoped_path_aliases_cannot_escape_ownership(self):
        (self.root / 'notes/source-link').symlink_to(self.root / 'src', target_is_directory=True)
        (self.root / 'src/original.py').write_text('original')
        (self.root / 'notes/hard.txt').hardlink_to(self.root / 'src/original.py')
        for path in ('notes/../src/a.py', 'notes/source-link/a.py', 'notes/hard.txt'):
            for platform in ('codex', 'claude'):
                self.check('deny', platform, self.edit('spec_writer', path, platform))
        outside = self.root.parent / 'outside'; outside.mkdir()
        (self.root / 'tests/link').symlink_to(outside, target_is_directory=True)
        for platform in ('codex', 'claude'):
            self.check('deny', platform, self.edit('implementer', 'tests/link/a.py', platform))
            self.check('allow', platform, self.edit('spec_writer', str(self.root / 'tests/good.py'), platform))
            self.check('allow', platform, self.edit('reviewer', str(outside / 'notes.txt'), platform))

    def test_commands_are_unrestricted_by_role_hook(self):
        commands = ['git diff', 'git switch -c task', 'git add -- src/a.py', 'git commit -m done', 'git push -u origin task', 'gh pr create --draft', 'python3 -m unittest discover -s tests -v', 'npm test', 'sh script.sh', 'cat src/a.py > tests/a.py', 'git checkout -- tests/a.py', 'echo hi; pwd', 'printf x | cat', 'python3 -c "print(1)"', 'shasum tests/a.py']
        for platform in ('codex', 'claude'):
            for role in (*ROLES, None, 'unknown'):
                for command in commands:
                    e = self.event(role, 'Bash' if platform == 'claude' else 'exec_command', {'command': command, 'workdir': str(self.root.parent), 'tty': True})
                    with self.subTest(platform=platform, role=role, command=command): self.check('allow', platform, e)

    def test_other_tools_and_inspection_do_not_require_role_identity(self):
        for platform in ('codex', 'claude'):
            for role in (*ROLES, None, 'unknown'):
                for tool in ('Read', 'Grep', 'Glob', 'spawn_agent', 'collaborationspawn_agent', 'Agent', 'Task', 'SendMessage', 'ToolSearch', 'SubagentHandback', 'write_stdin', 'mcp__arbitrary__write', 'functions.exec', 'collaboration.send_message'):
                    e = self.event(role, tool, {'query': 'anything'}); e['agent_id'] = ''
                    self.check('allow', platform, e)

    def test_bad_policy_or_event_denies_direct_edits(self):
        for event in (None, [], {}, {'hook_event_name': 'PostToolUse'}): self.check('allow', 'codex', event)
        self.check('allow', 'other', self.edit('implementer', 'src/a.py'))
        for changes in ({'schema_version': 99}, {'source_globs': 'src/**'}, {'source_globs': ['../outside/**']}, {'test_globs': 'tests/**'}):
            self.check('deny', 'codex', self.edit('implementer', 'src/a.py'), dict(self.policy, **changes))

    def test_cli_valid_decisions_and_invalid_input(self):
        policy_path = self.root / '.codex/policy.json'; policy_path.write_text(json.dumps(self.policy))
        argv = [sys.executable, '-B', str(SOURCE), '--platform', 'codex', '--root', str(self.root), '--policy', str(policy_path)]
        for payload, expected in ((json.dumps(self.edit('implementer', 'src/a.py')), 'allow'), ('{broken', 'allow')):
            result = subprocess.run(argv, input=payload, text=True, capture_output=True, timeout=10)
            self.assertEqual(0, result.returncode, result.stderr)
            output = json.loads(result.stdout)
            if expected == 'allow': self.assertEqual({}, output)
            else: self.assertEqual(expected, output['hookSpecificOutput']['permissionDecision'])
        policy_path.write_text('{broken')
        result = subprocess.run(argv, input=json.dumps(self.edit('implementer', 'src/a.py')), text=True, capture_output=True, timeout=10)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual('deny', json.loads(result.stdout)['hookSpecificOutput']['permissionDecision'])

if __name__ == '__main__': unittest.main()
