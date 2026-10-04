"""Future bundle removals and framework switches reconcile owned guidance."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class TemplateEvolution(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.work = Path(self.tmp.name).resolve()
        self.app = self.work / 'evolving_app'
        self.app.mkdir()
        self.bundle = self.work / 'bundle'
        self.bundle.mkdir()
        for item in ('scripts', 'app-template', 'app-template-ruby', 'app-template-zola'):
            shutil.copytree(ROOT / item, self.bundle / item, ignore=shutil.ignore_patterns('__pycache__', '*.pyc'))
        for item in ROOT.glob('*.sh'):
            shutil.copy2(item, self.bundle / item.name)
        self.cli('update', '--framework', 'phoenix')
        (self.app / '.docs/project-guidance.md').write_text('Local project rules retained.\n')
        (self.app / 'doc/custom-notes.md').write_text('Local notes retained.\n')
        (self.app / 'README.md').write_text('Application README retained.\n')

    def cli(self, operation, *args, expected=0):
        result = subprocess.run(['bash', str(self.bundle / 'agent-docs.sh'), operation, str(self.app), *args, '--json'],
                                env={**os.environ, 'PYTHONDONTWRITEBYTECODE': '1'},
                                cwd=self.work, capture_output=True, text=True)
        self.assertEqual(expected, result.returncode, result.stdout + result.stderr)
        return json.loads(result.stdout)

    def snapshot(self):
        return {str(p.relative_to(self.app)): (p.read_bytes(), p.stat().st_mtime_ns)
                for p in self.app.rglob('*') if p.is_file()}

    def remove_shared_module(self):
        # Retire the module from the entire bundle; the same basename is shared
        # by Phoenix and Sinatra, so removing only one masks stale-path validation.
        for name in ('app-template', 'app-template-ruby'):
            root = self.bundle / name
            (root / '.claude/payment-integration.md').unlink()
            manifest = root / 'claude-docs.manifest'
            manifest.write_text(''.join(line for line in manifest.read_text().splitlines(keepends=True)
                                        if not line.startswith('optional|payment-integration.md|')))
            guide = root / 'CLAUDE.md'
            guide.write_text(''.join(line for line in guide.read_text().splitlines(keepends=True)
                                     if '.claude/payment-integration.md' not in line))

    def assert_local_guidance(self):
        self.assertEqual('Local project rules retained.\n', (self.app / '.docs/project-guidance.md').read_text())
        self.assertEqual('Local notes retained.\n', (self.app / 'doc/custom-notes.md').read_text())
        self.assertEqual('Application README retained.\n', (self.app / 'README.md').read_text())

    def test_updated_bundle_removes_former_owned_module_in_both_layouts(self):
        self.remove_shared_module()
        before = self.snapshot()
        self.assertEqual('update', self.cli('check', expected=1)['status'])
        self.cli('diff', expected=1)
        self.assertEqual(before, self.snapshot())
        self.cli('update')
        for path in ('doc/payment-integration.md', '.claude/payment-integration.md'):
            self.assertFalse((self.app / path).exists(), path)
        self.assert_local_guidance()
        after = self.snapshot()
        self.cli('update')
        self.assertEqual(after, self.snapshot())

    def test_removed_bundle_module_with_local_edits_blocks_all_writes(self):
        self.remove_shared_module()
        path = self.app / 'doc/payment-integration.md'
        path.write_text(path.read_text() + '\nPreserve local edit until explicit reconciliation.\n')
        before = self.snapshot()
        self.assertEqual('drift', self.cli('check', expected=1)['status'])
        self.cli('update', expected=2)
        self.assertEqual(before, self.snapshot())
        self.assert_local_guidance()

    def test_framework_switch_removes_obsolete_guides_and_keeps_local_settings(self):
        settings_path = self.app / '.claude/settings.json'
        settings = json.loads(settings_path.read_text())
        settings['env'] = {'CUSTOM': 'keep'}
        custom = {'matcher': 'Read', 'hooks': [{'type': 'command', 'command': 'echo app-specific'}]}
        settings['hooks']['PreToolUse'].append(custom)
        settings_path.write_text(json.dumps(settings))
        self.assertTrue((self.app / '.claude/testing.md').is_file())
        self.cli('configure', '--framework', 'zola')
        for path in ('.claude/testing.md', 'doc/testing.md', '.claude/payment-integration.md',
                     'doc/payment-integration.md', '.claude/cloud-setup.sh', 'doc/hooks/cloud-setup.sh'):
            self.assertFalse((self.app / path).exists(), path)
        settings = json.loads(settings_path.read_text())
        self.assertEqual({'CUSTOM': 'keep'}, settings['env'])
        self.assertIn(custom, settings['hooks']['PreToolUse'])
        self.assertTrue(settings['hooks']['PreToolUse'])
        self.assertFalse(settings['hooks'].get('SessionStart'))
        self.assertTrue((self.app / 'doc/content.md').is_file())
        self.assert_local_guidance()
        self.assertEqual('current', self.cli('check')['status'])
        after = self.snapshot()
        self.cli('update')
        self.assertEqual(after, self.snapshot())

    def test_testing_guidance_bundle_upgrade_updates_both_platform_layouts(self):
        source = self.bundle / 'app-template/.claude/testing.md'
        source.write_text(source.read_text() + '\nShared testing guidance update.\n')
        before = self.snapshot()
        self.assertEqual('update', self.cli('check', expected=1)['status'])
        self.assertEqual(before, self.snapshot())
        self.cli('update')
        for path in ('.claude/testing.md', 'doc/testing.md'):
            self.assertIn('Shared testing guidance update.', (self.app / path).read_text())
        self.assert_local_guidance()
        self.assertEqual('current', self.cli('check')['status'])

    def test_local_testing_guidance_edit_outside_workflow_block_is_managed_drift(self):
        path = self.app / '.claude/testing.md'
        path.write_text('Local change to template guidance outside workflow block.\n' + path.read_text())
        before = self.snapshot()
        self.assertEqual('drift', self.cli('check', expected=1)['status'])
        self.cli('update', expected=2)
        self.assertEqual(before, self.snapshot())


if __name__ == '__main__':
    unittest.main()
