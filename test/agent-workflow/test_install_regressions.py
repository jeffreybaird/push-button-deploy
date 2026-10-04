"""Installer must activate roles and preserve externally owned hook entries."""
import importlib.util
import json
from pathlib import Path
import tempfile
import tomllib
import unittest

BASE = Path(__file__).resolve().parents[2] / 'scripts' / 'agent-workflow'
spec = importlib.util.spec_from_file_location('installer_regressions', BASE / 'installer.py')
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class InstallRegressions(unittest.TestCase):
    def test_enable_existing_agents_preserve_settings_without_default_model_override(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            (root / '.codex').mkdir()
            (root / '.codex/config.toml').write_text('[agents]\nenabled = false\nmax_threads = 3\n')
            policy = {'schema_version': 2, 'source_globs': ['src/**'], 'test_globs': ['tests/**'],
                      'artifact_roots': ['.agent-artifacts'], 'test_commands': []}
            installer.install(root, policy)
            config = tomllib.loads((root / '.codex/config.toml').read_text())
            self.assertTrue(config['agents']['enabled'])
            self.assertEqual(3, config['agents']['max_threads'])
            self.assertNotIn('model', config)
            for path in (root / '.codex/agents').glob('*.toml'):
                self.assertNotIn('model', tomllib.loads(path.read_text()))

    def test_unrelated_external_guard_registration_survives_install(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            (root / '.claude').mkdir()
            unrelated = {'matcher': 'Bash', 'hooks': [{'type': 'command', 'command':
                'python3 /opt/company/hooks/workflow_guard.py --platform claude --policy /opt/company/policy.json'}]}
            (root / '.claude/settings.json').write_text(json.dumps({'hooks': {'PreToolUse': [unrelated]}}))
            policy = {'schema_version': 2, 'source_globs': ['src/**'], 'test_globs': ['tests/**'],
                      'artifact_roots': ['.agent-artifacts'], 'test_commands': []}
            installer.install(root, policy)
            settings = json.loads((root / '.claude/settings.json').read_text())
            self.assertIn(unrelated, settings['hooks']['PreToolUse'])


    def test_exact_legacy_commands_removed_across_lifecycle_preserving_other_paths(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            (root / '.claude/hooks').mkdir(parents=True)
            script = root / '.claude/hooks/completion-gate.py'
            script.write_text('# retain legacy source\n')
            old = 'python3 "$CLAUDE_PROJECT_DIR/.claude/hooks/completion-gate.py"'
            external = 'python3 /opt/company/hooks/completion-gate.py'
            def registration(command):
                return {'hooks': [{'type': 'command', 'command': command}]}
            settings_path = root / '.claude/settings.json'
            settings_path.write_text(json.dumps({'hooks': {
                'PreToolUse': [registration(old), registration(external)],
                'TaskCompleted': [registration(old), registration(external)],
                'Stop': [registration(old), registration(external)]}}))
            policy = {'schema_version': 2, 'source_globs': ['src/**'], 'test_globs': ['tests/**'],
                      'artifact_roots': ['.agent-artifacts'], 'test_commands': [],
                      'legacy_commands': [old]}
            installer.install(root, policy)
            result = json.loads(settings_path.read_text())
            for event in ('PreToolUse', 'TaskCompleted', 'Stop'):
                self.assertNotIn(registration(old), result['hooks'].get(event, []))
                self.assertIn(registration(external), result['hooks'][event])
            self.assertEqual('# retain legacy source\n', script.read_text())


if __name__ == '__main__':
    unittest.main()
