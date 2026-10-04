"""Read-only accepted-test hashing must be usable through the native guard."""
import importlib.util
from pathlib import Path
import shlex
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1] / 'workflow_guard.py'
spec = importlib.util.spec_from_file_location('workflow_guard_hash_inspection', SOURCE)
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


class HashInspectionContract(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve() / 'repo'
        (self.root / 'tests').mkdir(parents=True)
        (self.root / 'tests/contract.py').write_text('accepted contract\n')
        (self.root / 'tests/other contract.py').write_text('other accepted contract\n')
        self.outside = self.root.parent / 'outside.py'
        self.outside.write_text('outside\n')
        (self.root / 'tests/link.py').symlink_to(self.outside)
        (self.root / 'tests/linked-dir').symlink_to(self.root / 'tests', target_is_directory=True)
        self.policy = {'schema_version': 1, 'test_globs': ['tests/**'],
                       'artifact_roots': ['.agent-artifacts'], 'test_commands': []}

    def check(self, expected, platform, role, command):
        event = {'hook_event_name': 'PreToolUse', 'cwd': str(self.root),
                 'tool_name': 'exec_command' if platform == 'codex' else 'Bash',
                 'tool_input': {'command': command}}
        if role is not None:
            event.update(agent_id='child', agent_type='workflow_' + role)
        result = guard.evaluate_event(platform, event, str(self.root), self.policy)
        self.assertEqual(expected, result['hookSpecificOutput']['permissionDecision'], result)

    def test_every_role_and_parent_can_hash_existing_repository_files(self):
        for platform in ('codex', 'claude'):
            for role in (None, 'spec_writer', 'implementer', 'runner', 'reviewer', 'orchestrator'):
                for paths in (['tests/contract.py'],
                              ['tests/contract.py', 'tests/other contract.py'],
                              [str(self.root / 'tests/contract.py')]):
                    with self.subTest(platform=platform, role=role, paths=paths):
                        self.check('allow', platform, role, shlex.join(['shasum', '-a', '256', '--', *paths]))

    def test_hashing_requires_exact_sha256_form_and_existing_canonical_files(self):
        commands = [
            'shasum -a 256 --',
            'shasum -a 1 -- tests/contract.py',
            'shasum -a 512 -- tests/contract.py',
            'shasum tests/contract.py',
            'shasum -a 256 tests/contract.py',
            'shasum -a 256 --check tests/contract.py',
            'shasum -a 256 -- --check',
            'shasum -a 256 -- -',
            'shasum -a 256 -- tests/missing.py',
            'shasum -a 256 -- tests',
            'shasum -a 256 -- tests/../tests/contract.py',
            'shasum -a 256 -- tests/link.py',
            'shasum -a 256 -- tests/linked-dir/contract.py',
            shlex.join(['shasum', '-a', '256', '--', str(self.outside)]),
            'shasum -a 256 -- ../outside.py',
            'shasum -a 256 -- tests/contract.py > tests/result',
            'shasum -a 256 -- tests/contract.py; touch tests/result',
            'shasum -a 256 -- $(touch tests/result)',
            'shasum -a 256 -- tests/contract.py | sh',
            'env shasum -a 256 -- tests/contract.py',
        ]
        for platform in ('codex', 'claude'):
            for command in commands:
                with self.subTest(platform=platform, command=command):
                    self.check('deny', platform, 'reviewer', command)
        self.assertFalse((self.root / 'tests/result').exists())


if __name__ == '__main__':
    unittest.main()
