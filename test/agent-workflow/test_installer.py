"""Installer integration contract in fresh, disposable repositories."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import tomllib
import unittest

BASE = Path(__file__).resolve().parents[2] / 'scripts' / 'agent-workflow'
spec = importlib.util.spec_from_file_location('installer', BASE / 'installer.py')
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class InstallerContract(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve() / 'repo'
        self.root.mkdir()
        self.policy = {'schema_version': 2, 'source_globs': ['src/**'], 'test_globs': ['tests/**'],
                       'artifact_roots': ['.agent-artifacts'],
                       'test_commands': [['python3', '-m', 'unittest']]}

    def snapshot(self):
        return {str(p.relative_to(self.root)): p.read_bytes()
                for p in self.root.rglob('*') if p.is_file() and not p.is_symlink()}

    def test_install_preserves_custom_instructions_and_is_idempotent(self):
        for name in ('AGENTS.md', 'CLAUDE.md'):
            (self.root / name).write_text('# Existing project\nKeep this exact custom instruction.\n')
        report = installer.install(self.root, self.policy)
        self.assertIsInstance(report, dict)
        first = self.snapshot()
        for name in ('AGENTS.md', 'CLAUDE.md'):
            self.assertIn(b'Keep this exact custom instruction.', first[name])
            self.assertIn(b'agent-workflow', first[name])
        installer.install(self.root, self.policy)
        self.assertEqual(first, self.snapshot())
        self.assertIn('.docs/agent-workflow.md', first)

    def test_reinstall_preserves_accepted_markdown_and_yaml_quote_formatting(self):
        (self.root / 'docs').mkdir()
        (self.root / 'docs/codex-agents.md').write_text('# Existing role guidance\n')
        installer.install(self.root, self.policy)
        formatted_paths = ['AGENTS.md', 'CLAUDE.md', 'docs/codex-agents.md']
        for name in formatted_paths:
            path = self.root / name
            original = path.read_text()
            marker = '<!-- BEGIN MANAGED AGENT WORKFLOW -->\n'
            self.assertEqual(1, original.count(marker))
            path.write_text(original.replace(marker, marker + '\n'))
        for path in sorted((self.root / '.claude/agents').glob('workflow-*.md')):
            lines = path.read_text().splitlines(keepends=True)
            for index, line in enumerate(lines):
                if line.startswith('description: '):
                    description = json.loads(line.removeprefix('description: '))
                    lines[index] = "description: '" + description.replace("'", "''") + "'\n"
            path.write_text(''.join(lines))
            formatted_paths.append(str(path.relative_to(self.root)))
        # The formatter's accepted output becomes the manifest baseline.
        manifest_path = self.root / '.codex/hooks/workflow-manifest.json'
        manifest = json.loads(manifest_path.read_text())
        for name in formatted_paths:
            manifest['sha256'][name] = hashlib.sha256((self.root / name).read_bytes()).hexdigest()
        manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
        accepted = self.snapshot()
        for _ in range(2):
            installer.install(self.root, self.policy)
            current = self.snapshot()
            self.assertEqual(accepted.keys(), current.keys())
            for name in accepted:
                self.assertEqual(accepted[name], current[name], name)

    def test_native_role_definitions_and_protected_runtime_policy(self):
        installer.install(self.root, self.policy)
        for folder, suffix in (('.codex/agents', '.toml'), ('.claude/agents', '.md')):
            paths = list((self.root / folder).glob('*' + suffix))
            self.assertEqual(5, len(paths), [p.name for p in paths])
            names = {p.stem.replace('-', '_') for p in paths}
            self.assertEqual({'workflow_' + role for role in
                              ('spec_writer', 'implementer', 'runner', 'reviewer', 'orchestrator')}, names)
        for folder in ('.codex/hooks', '.claude/hooks'):
            self.assertEqual((BASE / 'workflow_guard.py').read_bytes(),
                             (self.root / folder / 'workflow_guard.py').read_bytes())
            self.assertEqual(self.policy, json.loads((self.root / folder / 'policy.json').read_text()))

    def test_preserves_unrelated_settings_and_replaces_only_known_legacy_registration(self):
        (self.root / '.claude/hooks').mkdir(parents=True)
        legacy = self.root / '.claude/hooks/protect-tests.sh'
        legacy.write_text('# legacy script must remain\n')
        unrelated = {'matcher': 'Bash', 'hooks': [{'type': 'command', 'command': 'echo custom-observer'}]}
        old = {'matcher': 'Edit|Write', 'hooks': [{'type': 'command', 'command':
                    'bash "$CLAUDE_PROJECT_DIR/.claude/hooks/protect-tests.sh"'}]}
        (self.root / '.claude/settings.json').write_text(json.dumps({
            'env': {'CUSTOM_SETTING': 'keep'},
            'hooks': {'PreToolUse': [old, unrelated],
                      'SessionStart': [{'hooks': [{'type': 'command', 'command': 'echo session'}]}]}}))
        (self.root / '.codex').mkdir()
        (self.root / '.codex/config.toml').write_text('model = "custom-model"\n[custom]\nkeep = true\n')
        installer.install(self.root, self.policy)
        settings = json.loads((self.root / '.claude/settings.json').read_text())
        self.assertEqual('keep', settings['env']['CUSTOM_SETTING'])
        self.assertIn(unrelated, settings['hooks']['PreToolUse'])
        self.assertNotIn(old, settings['hooks']['PreToolUse'])
        self.assertIn('SessionStart', settings['hooks'])
        self.assertEqual('# legacy script must remain\n', legacy.read_text())
        config = tomllib.loads((self.root / '.codex/config.toml').read_text())
        self.assertEqual('custom-model', config['model'])
        self.assertTrue(config['custom']['keep'])

    def test_symlink_config_or_invalid_policy_rejected_before_mutation(self):
        outside = self.root.parent / 'outside.json'
        outside.write_text('{}')
        (self.root / '.claude').mkdir()
        (self.root / '.claude/settings.json').symlink_to(outside)
        before = self.snapshot()
        with self.assertRaises((ValueError, OSError)):
            installer.install(self.root, self.policy)
        self.assertEqual(before, self.snapshot())
        self.assertEqual('{}', outside.read_text())
        (self.root / '.claude/settings.json').unlink()
        before = self.snapshot()
        with self.assertRaises(ValueError):
            installer.install(self.root, {'schema_version': 99})
        self.assertEqual(before, self.snapshot())


if __name__ == '__main__':
    unittest.main()
