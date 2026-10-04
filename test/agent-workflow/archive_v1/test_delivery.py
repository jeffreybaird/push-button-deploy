"""Additive exact-command delivery contract; accepted core tests stay frozen."""
import copy
import importlib.util
from pathlib import Path
import shlex
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1] / 'workflow_guard.py'
spec = importlib.util.spec_from_file_location('workflow_guard_delivery', SOURCE)
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


class DeliveryContract(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve() / 'repo'
        self.root.mkdir()
        for directory in ('src', 'tests', '.codex/hooks', '.agent-artifacts'):
            (self.root / directory).mkdir(parents=True)
        self.commands = [
            ['git', 'branch', 'workflow/example'],
            ['git', 'add', '--', 'src/app.py', 'tests/test_app.py'],
            ['git', 'commit', '-m', 'Implement expected behavior'],
            ['git', 'push', 'origin', 'HEAD:refs/heads/workflow/example'],
            ['gh', 'pr', 'create', '--draft', '--title', 'Expected behavior',
             '--body', 'Verified implementation.', '--base', 'main',
             '--head', 'workflow/example'],
        ]
        self.policy = {'schema_version': 1, 'test_globs': ['tests/**'],
                       'artifact_roots': ['.agent-artifacts'], 'test_commands': [],
                       'delivery_commands': copy.deepcopy(self.commands)}

    def event(self, platform, role, command):
        event = {'hook_event_name': 'PreToolUse', 'cwd': str(self.root),
                 'tool_name': 'exec_command' if platform == 'codex' else 'Bash',
                 'tool_input': {'command': command}}
        if role is not None:
            event.update(agent_id='child-7', agent_type='workflow_' + role)
        return event

    def check(self, expected, platform, event, policy=None):
        result = guard.evaluate_event(platform, event, str(self.root),
                                      self.policy if policy is None else policy)
        output = result['hookSpecificOutput']
        self.assertEqual('PreToolUse', output['hookEventName'])
        self.assertEqual(expected, output['permissionDecision'], result)
        self.assertTrue(output['permissionDecisionReason'])

    def test_parent_and_orchestrator_exact_delivery_matrix_both_platforms(self):
        for platform in ('codex', 'claude'):
            for role in (None, 'orchestrator', 'spec_writer', 'implementer', 'runner', 'reviewer'):
                for argv in self.commands:
                    with self.subTest(platform=platform, role=role, argv=argv):
                        self.check('allow' if role in (None, 'orchestrator') else 'deny',
                                   platform, self.event(platform, role, shlex.join(argv)))

    def test_missing_empty_and_different_allowlist_do_not_grant_delivery(self):
        for policy in ({k: v for k, v in self.policy.items() if k != 'delivery_commands'},
                       dict(self.policy, delivery_commands=[]),
                       dict(self.policy, delivery_commands=[['git', 'branch', 'different']])):
            self.check('deny', 'codex', self.event('codex', None, 'git branch workflow/example'), policy)

    def test_exact_argv_not_prefix_and_shell_wrappers(self):
        for command in ('git branch workflow/example extra',
                        'git commit -m "Implement expected behavior" --amend',
                        'git branch workflow/example; touch tests/a.py',
                        'git branch workflow/example > src/log',
                        'env git branch workflow/example',
                        'sh -c "git branch workflow/example"'):
            with self.subTest(command=command):
                self.check('deny', 'codex', self.event('codex', None, command))

    def test_dangerous_commands_denied_even_when_exactly_configured(self):
        commands = [
            ['git', 'reset', '--hard'], ['git', 'clean', '-fd'],
            ['git', 'checkout', '--', 'tests/test_app.py'],
            ['git', 'merge', 'feature'], ['git', 'rebase', 'main'],
            ['git', 'push', '--force', 'origin', 'workflow/example'],
            ['git', 'push', '--force-with-lease', 'origin', 'workflow/example'],
            ['git', '-c', 'core.hooksPath=/tmp/hooks', 'commit', '-m', 'x'],
            ['git', 'config', 'core.hooksPath', '/tmp/hooks'],
            ['git', 'branch', '-D', 'feature'],
            ['gh', 'pr', 'create', '--title', 'x', '--body', 'x'],
            ['gh', 'pr', 'merge', '7'],
        ]
        for argv in commands:
            with self.subTest(argv=argv):
                policy = dict(self.policy, delivery_commands=[argv])
                for platform in ('codex', 'claude'):
                    self.check('deny', platform, self.event(platform, None, shlex.join(argv)), policy)

    def test_staging_requires_explicit_nonprotected_repository_paths(self):
        for path in ('.', '../outside', str(self.root.parent / 'outside'),
                     '.codex/hooks/policy.json', 'AGENTS.md', 'tests/CLAUDE.md', '--all'):
            argv = ['git', 'add', '--', path]
            with self.subTest(path=path):
                policy = dict(self.policy, delivery_commands=[argv])
                self.check('deny', 'codex', self.event('codex', None, shlex.join(argv)), policy)

    def test_partial_identity_cwd_and_pty_cannot_acquire_delivery(self):
        for identity in ({'agent_id': 'child'}, {'agent_type': 'workflow_orchestrator'},
                         {'agent_id': 'child', 'agent_type': 'unknown'},
                         {'agent_id': '', 'agent_type': ''}):
            event = self.event('codex', None, 'git branch workflow/example')
            event.update(identity)
            self.check('deny', 'codex', event)
        for field, value in (('tty', True), ('workdir', str(self.root.parent))):
            event = self.event('codex', None, 'git branch workflow/example')
            event['tool_input'][field] = value
            self.check('deny', 'codex', event)

    def test_malformed_delivery_policy_is_explicit_denial(self):
        for value in ('git branch workflow/example', ['git branch workflow/example'],
                      [[]], [['git', 7]], None):
            policy = dict(self.policy, delivery_commands=value)
            self.check('deny', 'codex', self.event('codex', None, 'git branch workflow/example'), policy)

    def test_dynamic_delivery_enabled_bounded_commands_for_each_task(self):
        (self.root / 'src/app.py').write_text('original')
        (self.root / '.agent-artifacts/pr.md').write_text('Draft body')
        policy = dict(self.policy, delivery_commands=[], delivery_enabled=True)
        commands = [
            ['git', 'switch', '-c', 'workflow/new-task-42'],
            ['git', 'add', '--', 'src/app.py'],
            ['git', 'commit', '-m', 'Fix new task behavior'],
            ['git', 'push', '-u', 'origin', 'workflow/new-task-42'],
            ['gh', 'pr', 'create', '--draft', '--title', 'New task',
             '--body-file', '.agent-artifacts/pr.md'],
        ]
        for platform in ('codex', 'claude'):
            for role in (None, 'orchestrator', 'spec_writer', 'implementer', 'runner', 'reviewer'):
                for argv in commands:
                    with self.subTest(platform=platform, role=role, argv=argv):
                        self.check('allow' if role in (None, 'orchestrator') else 'deny', platform,
                                   self.event(platform, role, shlex.join(argv)), policy)

    def test_dynamic_delivery_refuses_unsafe_arguments_and_disabled_policy(self):
        policy = dict(self.policy, delivery_commands=[], delivery_enabled=True)
        commands = [
            ['git', 'switch', '-c', '../escape'], ['git', 'switch', '-c', '-bad'],
            ['git', 'add', '--', '../outside'], ['git', 'add', '--', '.codex/hooks/policy.json'],
            ['git', 'commit', '-m', ''], ['git', 'commit', '-m', 'x', '--no-verify'],
            ['git', 'push', '-u', 'origin', 'main'], ['git', 'push', '-u', 'origin', 'master'],
            ['git', 'push', '--force', 'origin', 'workflow/example'],
            ['git', 'reset', '--hard'], ['git', 'clean', '-fd'],
            ['git', 'checkout', '--', 'src/app.py'], ['git', 'merge', 'feature'],
            ['git', 'rebase', 'main'], ['git', 'config', 'x', 'y'],
            ['gh', 'pr', 'create', '--title', 'x', '--body-file', '.agent-artifacts/pr.md'],
            ['gh', 'pr', 'create', '--draft', '--title', 'x', '--body-file', '../outside.md'],
        ]
        for argv in commands:
            with self.subTest(argv=argv):
                self.check('deny', 'codex', self.event('codex', None, shlex.join(argv)), policy)
        self.check('deny', 'codex', self.event('codex', None, 'git switch -c workflow/new'),
                   dict(policy, delivery_enabled=False))
        self.check('deny', 'codex', self.event('codex', None, 'git switch -c workflow/new'),
                   dict(policy, delivery_enabled='true'))


if __name__ == '__main__':
    unittest.main()
