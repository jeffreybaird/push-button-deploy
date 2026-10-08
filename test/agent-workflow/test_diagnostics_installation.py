"""Regeneration must preserve diagnostics and unrelated native hook configuration."""
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest

from test_installer import installer, BASE


class DiagnosticsInstallation(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve() / 'repository with spaces'
        self.root.mkdir()
        self.policy = {'schema_version': 2, 'source_globs': ['src/**'], 'test_globs': ['test/**']}
        subprocess.run(['git', 'init', '-q'], cwd=self.root, check=True)

    def snapshot(self):
        return {str(path.relative_to(self.root)): path.read_bytes()
                for path in self.root.rglob('*') if path.is_file() and '.git' not in path.relative_to(self.root).parts}

    def test_generated_wrapper_docs_ignore_and_manifest_match_actual_bytes(self):
        (self.root / '.gitignore').write_text('# Custom ignore\nprivate-custom/\n')
        metadata = {'version': 'test-version', 'source_commit': 'test-source'}
        installer.install(self.root, self.policy, installer_metadata=metadata)
        wrapper = self.root / '.codex/hooks/hook_diagnostics.py'
        self.assertEqual((BASE / 'hook_diagnostics.py').read_bytes(), wrapper.read_bytes())
        self.assertFalse((self.root / '.claude/hooks/hook_diagnostics.py').exists())
        ignore = (self.root / '.gitignore').read_text()
        self.assertIn('# Custom ignore\nprivate-custom/\n', ignore)
        self.assertEqual(1, ignore.splitlines().count('/.agent-diagnostics/'))
        manifest = json.loads((self.root / '.codex/hooks/workflow-manifest.json').read_text())
        self.assertEqual(metadata, manifest['installer'])
        for path in ('.codex/hooks/hook_diagnostics.py', '.codex/hooks.json',
                     '.gitignore', '.docs/hook-diagnostics.md'):
            self.assertIn(path, manifest['sha256'])
        for path, digest in manifest['sha256'].items():
            self.assertEqual(hashlib.sha256((self.root / path).read_bytes()).hexdigest(), digest, path)
        docs = (self.root / '.docs/hook-diagnostics.md').read_text()
        for requirement in ('SIGKILL', 'timeout', 'Desktop', 'CLI', 'startup'):
            self.assertIn(requirement.lower(), docs.lower())
        self.assertIn('activation', docs.lower())
        first = self.snapshot()
        installer.install(self.root, self.policy)
        self.assertEqual(first, self.snapshot())
        wrapper.write_text('# simulated generated drift\n')
        installer.install(self.root, self.policy)
        self.assertEqual(first, self.snapshot())
        (self.root / '.agent-diagnostics').mkdir()
        (self.root / '.agent-diagnostics/hooks.jsonl').write_text('local diagnostic\n')
        result = subprocess.run(['git', 'check-ignore', '.agent-diagnostics/hooks.jsonl'],
                                cwd=self.root, capture_output=True, text=True)
        self.assertEqual(0, result.returncode)

    def test_upgrade_and_regeneration_keep_mixed_unrelated_commands_and_settings(self):
        (self.root / '.codex').mkdir()
        custom = {'type': 'command', 'command': 'echo custom', 'timeout': 19}
        old = {'type': 'command', 'command': installer.CODEX_GUARD_COMMAND, 'timeout': 5}
        mention = {'type': 'command', 'command': 'echo "' + installer.CODEX_AUDIT_SCRIPT + '" --platform codex'}
        wrapper_mention = {'type': 'command', 'command': 'echo "' + installer.CODEX_AUDIT_ROOT +
                           '/.codex/hooks/hook_diagnostics.py" --hook workflow_guard --event PreToolUse'}
        mixed = {'matcher': 'custom-matcher', 'description': 'keep metadata',
                 'hooks': [custom, old, mention, wrapper_mention]}
        session = {'hooks': [custom]}
        path = self.root / '.codex/hooks.json'
        path.write_text(json.dumps({'custom_setting': {'keep': True}, 'hooks': {
            'PreToolUse': [mixed], 'SessionStart': [session]}}))
        (self.root / '.codex/config.toml').write_text('model = "existing-model"\n[custom]\nkeep = true\n')
        for _ in range(3):
            installer.install(self.root, self.policy)
            config = json.loads(path.read_text())
            self.assertEqual({'keep': True}, config['custom_setting'])
            expected = dict(mixed, hooks=[custom, mention, wrapper_mention])
            self.assertIn(expected, config['hooks']['PreToolUse'])
            self.assertEqual([session], config['hooks']['SessionStart'])
            generated = []
            for event, registrations in config['hooks'].items():
                for registration in registrations:
                    for hook in registration['hooks']:
                        command = hook['command']
                        if command.startswith('echo '):
                            continue
                        if 'hook_diagnostics.py' in command:
                            argv = shlex.split(command)
                            self.assertEqual(1, sum('hook_diagnostics.py' in arg for arg in argv))
                            self.assertEqual(event, argv[argv.index('--event') + 1])
                            identity = argv[argv.index('--hook') + 1]
                            self.assertIn(identity + '.py', command)
                            self.assertIn('--platform codex', command)
                            self.assertFalse(hook.get('async', False))
                            generated.append((event, identity))
            self.assertCountEqual([('PreToolUse', 'workflow_guard'), ('PreToolUse', 'workflow_audit'),
                                   ('PostToolUse', 'workflow_audit')], generated)
        self.assertIn('model = "existing-model"', (self.root / '.codex/config.toml').read_text())
        claude = json.loads((self.root / '.claude/settings.json').read_text())
        self.assertNotIn('hook_diagnostics.py', json.dumps(claude))

    def test_generated_shell_commands_execute_in_repository_with_spaces(self):
        installer.install(self.root, self.policy)
        hooks = json.loads((self.root / '.codex/hooks.json').read_text())['hooks']
        env = dict(os.environ)
        for event, registrations in hooks.items():
            for registration in registrations:
                for hook in registration['hooks']:
                    if 'hook_diagnostics.py' not in hook['command']:
                        continue
                    payload = {'hook_event_name': event, 'tool_name': 'unrelated-native-tool',
                               'tool_input': {'secret': 'PAYLOAD_SECRET'}}
                    result = subprocess.run(['sh', '-c', hook['command']], cwd=self.root, env=env,
                                            input=json.dumps(payload), capture_output=True, text=True, timeout=10)
                    self.assertEqual((0, '{}\n', ''), (result.returncode, result.stdout, result.stderr))
        records = [json.loads(line) for line in
                   (self.root / '.agent-diagnostics/hooks.jsonl').read_text().splitlines()]
        self.assertCountEqual([('PreToolUse', 'workflow_guard'), ('PreToolUse', 'workflow_audit'),
                               ('PostToolUse', 'workflow_audit')],
                              [(record['event'], record['hook']) for record in records])


if __name__ == '__main__':
    unittest.main()
