"""Retired template options must not strand apps with saved exclusions."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class SavedSelectionEvolution(unittest.TestCase):
    def test_retired_saved_skips_are_pruned_without_resetting_other_preferences(self):
        with tempfile.TemporaryDirectory() as temporary:
            work = Path(temporary).resolve()
            bundle = work / 'bundle'
            bundle.mkdir()
            for item in ('scripts', 'app-template', 'app-template-ruby', 'app-template-rails', 'app-template-zola'):
                shutil.copytree(ROOT / item, bundle / item, ignore=shutil.ignore_patterns('__pycache__', '*.pyc'))
            for item in ROOT.glob('*.sh'):
                shutil.copy2(item, bundle / item.name)
            app = work / 'app'
            app.mkdir()

            def cli(operation, *args, expected=0):
                result = subprocess.run(['bash', str(bundle / 'agent-docs.sh'), operation, str(app), *args, '--json'],
                                        env={**os.environ, 'PYTHONDONTWRITEBYTECODE': '1'},
                                        cwd=work, capture_output=True, text=True)
                self.assertEqual(expected, result.returncode, result.stdout + result.stderr)
                return json.loads(result.stdout)

            def snapshot():
                return {str(path.relative_to(app)): (path.read_bytes(), path.stat().st_mtime_ns)
                        for path in app.rglob('*') if path.is_file()}

            cli('update', '--framework', 'phoenix')
            cli('configure', '--skip-module', 'rbac.md', '--skip-module', 'payment-integration.md',
                '--skip-agent', 'test-writer.md', '--skip-agent', 'code-reviewer.md', '--hook', 'format', '--no-setup')
            (app / '.docs/project-guidance.md').write_text('App-specific rules.\n')
            for name in ('app-template', 'app-template-ruby'):
                template = bundle / name
                (template / '.claude/payment-integration.md').unlink()
                (template / '.claude/agents/test-writer.md').unlink()
                manifest = template / 'claude-docs.manifest'
                manifest.write_text(''.join(line for line in manifest.read_text().splitlines(keepends=True)
                                            if not line.startswith(('optional|payment-integration.md|', 'agent|test-writer.md|'))))
                guide = template / 'CLAUDE.md'
                guide.write_text(''.join(line for line in guide.read_text().splitlines(keepends=True)
                                         if not any(value in line for value in ('payment-integration.md', 'test-writer.md'))))
            before = snapshot()
            self.assertEqual('update', cli('check', expected=1)['status'])
            cli('diff', expected=1)
            self.assertEqual(before, snapshot())
            cli('update')
            selection = json.loads((app / '.agent-docs-manifest.json').read_text())['selection']
            self.assertEqual(['rbac.md'], selection['skip_modules'])
            self.assertEqual(['code-reviewer.md'], selection['skip_agents'])
            self.assertEqual('format', selection['hook'])
            self.assertTrue(selection['no_setup'])
            for rel in ('doc/rbac.md', '.claude/rbac.md', 'doc/agents/code-reviewer.md',
                        '.claude/agents/code-reviewer.md', 'doc/hooks/cloud-setup.sh'):
                self.assertFalse((app / rel).exists(), rel)
            self.assertEqual('App-specific rules.\n', (app / '.docs/project-guidance.md').read_text())
            after = snapshot()
            self.assertEqual('current', cli('check')['status'])
            cli('update')
            self.assertEqual(after, snapshot())
            # Retired recorded choices normalize; an explicit new invalid choice
            # remains an error rather than being silently discarded.
            cli('configure', '--skip-module', 'payment-integration.md', expected=2)
            self.assertEqual(after, snapshot())


if __name__ == '__main__':
    unittest.main()
