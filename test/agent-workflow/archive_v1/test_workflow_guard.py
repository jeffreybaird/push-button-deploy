"""Behavior contract. Run only after independent review accepts these tests."""
import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1] / 'workflow_guard.py'
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
        for folder in ('src', 'tests', 'test', 'spec', 'features', 'fixtures',
                       '.agent-artifacts', '.codex', '.claude/hooks', '.docs'):
            (self.root / folder).mkdir(parents=True, exist_ok=True)
        self.policy = {
            'schema_version': 1,
            'test_globs': ['tests/**', 'test/**', 'spec/**', 'features/**',
                           'fixtures/**', '**/*_test.py', '**/*.test.js'],
            'artifact_roots': ['.agent-artifacts'],
            'test_commands': [['python3', '-m', 'unittest', 'discover', '-s', 'tests']],
        }

    def event(self, role, tool, payload):
        e = {'hook_event_name': 'PreToolUse', 'cwd': str(self.root),
             'tool_name': tool, 'tool_input': payload}
        if role is not None:
            e.update(agent_id='child-17', agent_type='workflow_' + role)
        return e

    def check(self, expected, platform, event, policy=None):
        result = guard.evaluate_event(platform, event, str(self.root),
                                      self.policy if policy is None else policy)
        output = result['hookSpecificOutput']
        self.assertEqual('PreToolUse', output['hookEventName'])
        self.assertEqual(expected, output['permissionDecision'], result)
        self.assertIsInstance(output['permissionDecisionReason'], str)
        self.assertTrue(output['permissionDecisionReason'].strip())

    def edit(self, role, path, platform='codex'):
        if platform == 'codex':
            return self.event(role, 'apply_patch', {'command':
                f'*** Begin Patch\n*** Add File: {path}\n+contract\n*** End Patch'})
        return self.event(role, 'Write', {'file_path': path, 'content': 'contract'})

    def shell(self, role, command, platform):
        return self.event(role, 'exec_command' if platform == 'codex' else 'Bash',
                          {'command': command})

    def test_role_write_matrix_both_platforms(self):
        for platform in ('codex', 'claude'):
            for role in ROLES:
                for path, owner in [('tests/new.py', 'spec_writer'),
                                    ('src/new.py', 'implementer'),
                                    ('.agent-artifacts/run.log', 'runner')]:
                    with self.subTest(platform=platform, role=role, path=path):
                        self.check('allow' if role == owner else 'deny', platform,
                                   self.edit(role, path, platform))
        self.assertFalse((self.root / 'src/new.py').exists())

    def test_test_layouts_and_colocated_tests(self):
        for path in ('test/unit.py', 'spec/login_spec.rb', 'features/login.feature',
                     'fixtures/login.json', 'src/foo_test.py', 'src/foo.test.js'):
            with self.subTest(path=path):
                self.check('allow', 'codex', self.edit('spec_writer', path))
                self.check('deny', 'codex', self.edit('implementer', path))
        self.check('allow', 'codex', self.edit('implementer', 'README.md'))

    def test_protected_policy_and_instruction_files_all_roles(self):
        for role in ROLES:
            for path in ('.codex/hooks/policy.json', '.claude/hooks/guard.py',
                         '.git/config', 'AGENTS.md', 'CLAUDE.md',
                         '.docs/agent-workflow.md', 'tests/AGENTS.md',
                         'tests/.codex/policy.json', '.agent-artifacts/CLAUDE.md'):
                with self.subTest(role=role, path=path):
                    self.check('deny', 'codex', self.edit(role, path))

    def test_identity_normalization_and_untrusted_claims(self):
        for name in ('spec_writer', 'spec-writer', 'workflow_spec_writer',
                     'workflow-spec-writer'):
            e = self.edit('spec_writer', 'tests/a.py')
            e['agent_type'] = name
            self.check('allow', 'codex', e)
        for identity in ({}, {'agent_id': 'x'}, {'agent_type': 'spec_writer'},
                         {'agent_id': '', 'agent_type': 'spec_writer'},
                         {'agent_id': 'x', 'agent_type': 'unknown'}):
            e = self.edit(None, 'tests/a.py')
            e.update(identity)
            e['tool_input']['agent_type'] = 'spec_writer'
            self.check('deny', 'codex', e)

    def test_claude_edit_and_notebook_paths(self):
        for tool, key, path in [('Edit', 'file_path', 'tests/a.py'),
                                ('NotebookEdit', 'notebook_path', 'tests/a.ipynb')]:
            payload = {key: str(self.root / path), 'old_string': 'a',
                       'new_string': 'b', 'new_source': 'b'}
            self.check('allow', 'claude', self.event('spec_writer', tool, payload))
            self.check('deny', 'claude', self.event('implementer', tool, payload))
        self.check('deny', 'claude', self.event('implementer', 'Edit',
                                               {'path': 'src/a.py'}))

    def test_add_update_delete_move_all_operands(self):
        for operation in ('*** Delete File: tests/a.py',
                          '*** Update File: tests/a.py\n@@\n-old\n+new',
                          '*** Update File: tests/a.py\n*** Move to: tests/b.py\n@@\n-old\n+new'):
            e = self.event('spec_writer', 'apply_patch', {'command':
                '*** Begin Patch\n' + operation + '\n*** End Patch'})
            self.check('allow', 'codex', e)
        for command in (
            '*** Begin Patch\n*** Update File: tests/a.py\n*** Move to: src/a.py\n@@\n-old\n+new\n*** End Patch',
            '*** Begin Patch\n*** Add File: tests/a.py\n+x\n*** Delete File: src/a.py\n*** End Patch',
            '*** Begin Patch\n*** Delete File: src/a.py\n*** End Patch'):
            self.check('deny', 'codex', self.event('spec_writer', 'apply_patch',
                                                  {'command': command}))

    def test_malformed_patch_and_wrong_shape_deny(self):
        for payload in ({'patch': '*** Begin Patch\n*** Delete File: tests/a\n*** End Patch'},
                        {'command': ''}, {'command': '*** Begin Patch\n*** End Patch'},
                        {'command': '*** Begin Patch\n*** Add File: tests/a\n*** End Patch'},
                        {'command': '*** Begin Patch\n*** Delete File: tests/a\n*** End Patch\njunk'}):
            self.check('deny', 'codex', self.event('spec_writer', 'apply_patch', payload))

    def test_paths_reject_escape_symlink_directory_hardlink(self):
        outside = self.root.parent / 'outside'
        outside.mkdir()
        (self.root / 'tests/link').symlink_to(outside, target_is_directory=True)
        (outside / 'original').write_text('original')
        (self.root / 'tests/hard').hardlink_to(outside / 'original')
        for path in ('tests/../src/a.py', '../outside/a.py', str(outside / 'a.py'),
                     'tests/link/a.py', 'tests', 'tests/hard'):
            with self.subTest(path=path):
                for platform in ('codex', 'claude'):
                    self.check('deny', platform, self.edit('spec_writer', path, platform))
        self.check('allow', 'codex', self.edit('spec_writer', str(self.root / 'tests/good.py')))

    def test_inspection_shell_every_role_and_parent(self):
        for platform in ('codex', 'claude'):
            for role in (*ROLES, None):
                for command in ('cat src/app.py', 'rg --files', 'rg -n needle src',
                                'git status --short', 'git diff --no-ext-diff --no-textconv'):
                    with self.subTest(platform=platform, role=role, command=command):
                        self.check('allow', platform, self.shell(role, command, platform))

    def test_claude_native_inspection_every_role_and_parent(self):
        for role in (*ROLES, None):
            for tool, payload in [('Read', {'file_path': str(self.root / 'src/app.py')}),
                                  ('Glob', {'pattern': '**/*.py'}),
                                  ('Grep', {'pattern': 'needle', 'path': str(self.root)})]:
                self.check('allow', 'claude', self.event(role, tool, payload))

    def test_shell_no_mutation_or_program_execution_escape(self):
        commands = ('cat src/app.py > tests/a.py', 'cat src/app.py; touch tests/a',
                    'cat $(touch tests/a)', 'cat `touch tests/a`', 'cat src/a | sh',
                    'cat src/a\ntouch tests/a', 'rg --pre python needle src',
                    'rg -z needle src', 'git diff --output=tests/diff',
                    'git diff', 'git diff --ext-diff', 'git diff --textconv',
                    'git -c core.pager=sh diff', 'python3 -c "print(1)"',
                    'sh script.sh', 'env python3 -m unittest discover -s tests',
                    'git checkout -- tests/a.py')
        for platform in ('codex', 'claude'):
            for command in commands:
                with self.subTest(platform=platform, command=command):
                    self.check('deny', platform, self.shell('runner', command, platform))

    def test_exact_runner_test_command_and_no_suffix(self):
        command = 'python3 -m unittest discover -s tests'
        for platform in ('codex', 'claude'):
            for role in (*ROLES, None):
                self.check('allow' if role == 'runner' else 'deny', platform,
                           self.shell(role, command, platform))
            for suffix in (' -v', '; touch tests/a', ' > src/output'):
                self.check('deny', platform, self.shell('runner', command + suffix, platform))

    def test_root_and_orchestrator_only_delegate(self):
        for platform, tool in [('codex', 'spawn_agent'), ('claude', 'Agent'), ('claude', 'Task')]:
            for role in (*ROLES, None):
                self.check('allow' if role in (None, 'orchestrator') else 'deny',
                           platform, self.event(role, tool, {'prompt': 'review'}))
        for identity in ({'agent_id': 'child'}, {'agent_type': 'orchestrator'},
                         {'agent_id': '', 'agent_type': ''},
                         {'agent_id': 'child', 'agent_type': 'unknown'}):
            e = self.event(None, 'spawn_agent', {})
            e.update(identity)
            self.check('deny', 'codex', e)

    def test_codex_native_bash_shape_and_interactive_start(self):
        self.check('allow', 'codex', self.event('reviewer', 'Bash',
                                               {'command': 'git status --short'}))
        self.check('deny', 'codex', self.event('reviewer', 'Bash',
                                              {'command': 'touch tests/a'}))
        e = self.shell('runner', 'cat src/app.py', 'codex')
        e['tool_input']['tty'] = True
        self.check('deny', 'codex', e)

    def test_cwd_mismatch_and_unknown_tools_deny(self):
        e = self.edit('implementer', 'src/a.py')
        e['cwd'] = str(self.root.parent)
        self.check('deny', 'codex', e)
        e = self.shell('runner', 'python3 -m unittest discover -s tests', 'codex')
        e['tool_input']['workdir'] = str(self.root.parent)
        self.check('deny', 'codex', e)
        for tool in ('write_stdin', 'mcp__arbitrary__write', 'functions.exec'):
            self.check('deny', 'codex', self.event('implementer', tool, {}))

    def test_bad_event_platform_policy_denied(self):
        for event in (None, [], {}, {'hook_event_name': 'PostToolUse'}):
            self.check('deny', 'codex', event)
        self.check('deny', 'other', self.edit('implementer', 'src/a.py'))
        for update in ({'schema_version': 2}, {'test_globs': 'tests/**'},
                       {'artifact_roots': ['../outside']}, {'test_commands': ['pytest']}):
            policy = copy.deepcopy(self.policy)
            policy.update(update)
            self.check('deny', 'codex', self.edit('implementer', 'src/a.py'), policy)

    def test_cli_allow_and_valid_denial_for_bad_input_or_policy(self):
        policy_path = self.root / '.codex/policy.json'
        policy_path.write_text(json.dumps(self.policy))
        argv = [sys.executable, '-B', str(SOURCE), '--platform', 'codex',
                '--root', str(self.root), '--policy', str(policy_path)]
        for payload, expected in ((json.dumps(self.edit('implementer', 'src/a.py')), 'allow'),
                                  ('{broken', 'deny')):
            result = subprocess.run(argv, input=payload, text=True, capture_output=True, timeout=10)
            self.assertEqual(0, result.returncode, result.stderr)
            self.assertEqual(expected, json.loads(result.stdout)['hookSpecificOutput']['permissionDecision'])
        policy_path.write_text('{broken')
        result = subprocess.run(argv, input=json.dumps(self.edit('implementer', 'src/a.py')),
                                text=True, capture_output=True, timeout=10)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual('deny', json.loads(result.stdout)['hookSpecificOutput']['permissionDecision'])


if __name__ == '__main__':
    unittest.main()
