"""React's one shared convention file survives every supported rendering path."""
import gzip
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class ReactSharedGuide(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.app = self.work / 'browser-app'
        self.app.mkdir()

    def command(self, *args, expected=0):
        result = subprocess.run(['bash', *map(str, args)], capture_output=True, text=True,
                                env={**os.environ, 'PYTHONDONTWRITEBYTECODE': '1'})
        self.assertEqual(expected, result.returncode, result.stdout + result.stderr)
        return result

    def lifecycle(self, operation='update', expected=0):
        return self.command(ROOT / 'agent-docs.sh', operation, self.app, '--json', expected=expected)

    def snapshot(self):
        return {str(path.relative_to(self.app)): (path.read_bytes(), path.stat().st_mtime_ns)
                for path in self.app.rglob('*') if path.is_file()}

    def legacy(self):
        with gzip.open(ROOT / 'test/fixtures/agent-docs-legacy/react.json.gz', 'rt') as source:
            for name, contents in json.load(source).items():
                path = self.app / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(contents)

    def assert_shared(self):
        guide = self.app / '.docs/react.md'
        self.assertTrue(guide.is_file())
        self.assertTrue(guide.read_text().strip())
        for obsolete in ('.claude/react.md', 'doc/react.md'):
            self.assertFalse((self.app / obsolete).exists(), obsolete)
        for entry in ('AGENTS.md', 'CLAUDE.md'):
            text = (self.app / entry).read_text()
            self.assertIn('.docs/react.md', text)
            self.assertNotIn('.claude/react.md', text)
            self.assertNotIn('`doc/react.md', text)
        manifest = json.loads((self.app / '.agent-docs-manifest.json').read_text())
        self.assertIn('.docs/react.md', manifest['template_files'])
        self.assertIn('.docs/react.md', manifest['files'])
        self.assertNotIn('.claude/react.md', manifest['files'])
        self.assertNotIn('doc/react.md', manifest['files'])

    def bundle(self):
        bundle = self.work / 'bundle'
        bundle.mkdir()
        for name in ('scripts', 'app-template', 'app-template-ruby', 'app-template-rails',
                     'app-template-zola', 'app-template-react'):
            shutil.copytree(ROOT / name, bundle / name)
        for path in ROOT.glob('*.sh'):
            shutil.copy2(path, bundle / path.name)
        return bundle

    def test_canonical_source_changes_installer_fingerprint(self):
        bundle = self.bundle()
        source = bundle / 'app-template-react/.docs/react.md'
        source.parent.mkdir(exist_ok=True)
        source.write_text('Shared conventions before update.\n')
        script = ("import sys; sys.path.insert(0, sys.argv[1]); "
                  "import workflow; print(workflow.release_metadata()['source_commit'])")
        def fingerprint():
            return subprocess.check_output(['python3', '-c', script,
                                            str(bundle / 'scripts/agent-workflow')], text=True).strip()
        before = fingerprint()
        source.write_text('Shared conventions after meaningful update.\n')
        self.assertNotEqual(before, fingerprint())

    def test_custom_docs_only_renderer_preserves_optional_selection(self):
        template = self.work / 'custom'
        (template / '.docs').mkdir(parents=True)
        (template / 'CLAUDE.md').write_text('# Browser app\n- `.docs/react.md` — conventions.\n')
        (template / 'claude-docs.manifest').write_text('placeholders|ExampleApp|example_app\noptional|react.md|React conventions\n')
        (template / '.docs/react.md').write_text('Shared browser conventions.\n')
        script = 'fail() { echo "$*" >&2; exit 1; }; log() { :; }; . "$1/scripts/claude-docs.sh"; CD_SKIP_MODULES="$4" cd_inject "$2" "$3" BrowserApp browser_app'
        for skip in ('', 'react.md'):
            with self.subTest(skip=skip):
                app = self.work / ('selected' if not skip else 'skipped')
                self.command('-c', script, 'render', ROOT, template, app, skip)
                self.assertEqual(not bool(skip), (app / '.docs/react.md').is_file())
                for entry in ('AGENTS.md', 'CLAUDE.md'):
                    self.assertEqual(not bool(skip), '.docs/react.md' in (app / entry).read_text())
                self.assertFalse((app / '.claude/react.md').exists())
                self.assertFalse((app / 'doc/react.md').exists())

    def test_ambiguous_or_reserved_shared_template_fails_before_writes(self):
        bundle = self.bundle()
        template = bundle / 'app-template-react'
        (template / '.docs').mkdir(exist_ok=True)
        (template / '.claude').mkdir(exist_ok=True)
        # Test either source layout without relying on the present source location.
        for name in ('react.md', 'project-guidance.md', 'agent-workflow.md'):
            with self.subTest(name=name):
                paths = [template / '.docs' / name]
                if name == 'react.md':
                    paths.append(template / '.claude' / name)
                saved = {path: path.read_bytes() if path.exists() else None for path in paths}
                for path in paths:
                    path.write_text('Ambiguous or reserved template content.\n')
                before = self.snapshot()
                self.command(bundle / 'agent-docs.sh', 'update', self.app,
                             '--framework', 'react', expected=2)
                self.assertEqual(before, self.snapshot())
                for path, content in saved.items():
                    if content is None:
                        path.unlink()
                    else:
                        path.write_bytes(content)

    def test_template_has_one_platform_neutral_source(self):
        template = ROOT / 'app-template-react'
        self.assertTrue((template / '.docs/react.md').is_file())
        self.assertFalse((template / '.claude/react.md').exists())
        self.assertFalse((template / 'doc/react.md').exists())
        self.assertIn('.docs/react.md', (template / 'CLAUDE.md').read_text())

    def test_fresh_scaffold_installs_one_shared_guide(self):
        self.command(ROOT / 'scripts/new-react-app.sh', self.app)
        self.assert_shared()
        before = self.snapshot()
        self.lifecycle('check')
        self.lifecycle()
        self.assertEqual(before, self.snapshot())

    def test_legacy_public_renderer_uses_same_shared_guide(self):
        self.command(ROOT / 'claude-docs.sh', '--all', '--framework', 'react', self.app)
        self.assert_shared()

    def test_managed_legacy_copies_migrate_and_local_rules_survive(self):
        self.legacy()
        local = self.app / '.docs/project-guidance.md'
        local.write_text('Preserve application-specific constraints.\n')
        for entry in ('AGENTS.md', 'CLAUDE.md'):
            path = self.app / entry
            path.write_text(path.read_text() + '\nLocal rule outside managed regions.\n')
        before = self.snapshot()
        self.lifecycle('check', expected=1)
        self.lifecycle('diff', expected=1)
        self.assertEqual(before, self.snapshot())
        self.lifecycle()
        self.assert_shared()
        self.assertEqual('Preserve application-specific constraints.\n', local.read_text())
        for entry in ('AGENTS.md', 'CLAUDE.md'):
            self.assertIn('Local rule outside managed regions.', (self.app / entry).read_text())
        after = self.snapshot()
        self.lifecycle()
        self.assertEqual(after, self.snapshot())

    def test_edited_legacy_copy_blocks_migration_without_writes(self):
        for old in ('.claude/react.md', 'doc/react.md'):
            with self.subTest(old=old):
                self.legacy()
                path = self.app / old
                path.write_text(path.read_text() + '\nKeep this local modification.\n')
                before = self.snapshot()
                self.lifecycle(expected=2)
                self.assertEqual(before, self.snapshot())
                shutil.rmtree(self.app)
                self.app.mkdir()

    def test_unmanaged_destination_and_managed_drift_are_preserved(self):
        self.legacy()
        guide = self.app / '.docs/react.md'
        guide.write_text('Unmanaged local React conventions.\n')
        before = self.snapshot()
        self.lifecycle(expected=2)
        self.assertEqual(before, self.snapshot())
        shutil.rmtree(self.app)
        self.app.mkdir()
        self.command(ROOT / 'agent-docs.sh', 'update', self.app, '--framework', 'react')
        guide.write_text(guide.read_text() + '\nLocal managed-file edit.\n')
        before = self.snapshot()
        self.lifecycle(expected=2)
        self.assertEqual(before, self.snapshot())


if __name__ == '__main__':
    unittest.main()
