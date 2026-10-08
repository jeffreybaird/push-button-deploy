"""Shared guide output and migration use one canonical .docs directory."""
import gzip
import hashlib
import json
import os
from pathlib import Path
import subprocess
import shutil
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
FRAMEWORKS = ('phoenix', 'sinatra', 'rails', 'react', 'zola')
TEMPLATES = dict(zip(FRAMEWORKS, ('app-template', 'app-template-ruby', 'app-template-rails', 'app-template-react', 'app-template-zola')))

REVIEWER_PR_EVIDENCE = (
    ' Every PR must include relevant Ruby Cucumber or Elixir Cucumberex scenario content or executed '
    'scenario output, plus actual Ruby RSpec --format documentation or Elixir ExUnit --trace output '
    'with commands and results; verify honest failures, skipped and pending examples, reasoned N/A '
    'only for unrelated ecosystems or changes, and completion of required full quality gates under '
    '.docs/agent-workflow.md#pull-request-test-evidence. Mandatory tooling missing from a fresh '
    'generated project is a defect, not N/A. Names or links alone are insufficient acceptance '
    'evidence. Never accept fabricated output.'
)

# Intentional migration additions, independent of the production renderer.
COMPACT_COORDINATION = (
    ' Use compact handoffs with expected behavior, owned paths, relevant repository guidance, '
    'accepted-test hashes when available, validation commands, and evidence paths. '
    'Return only completion, blockers, and material findings; follow the coordination and '
    'evidence guidance in .docs/agent-workflow.md.'
)
FULL_EVIDENCE = (
    ' Preserve full evidence in files or artifacts. The independent reviewer must read '
    'the full evidence and inspect the final diff.'
)
ORCHESTRATOR_COORDINATION = (
    ' By default, use one main orchestrator for a single change and reuse existing role agents.'
)
CODEX_BOUNDED_CONTEXT = (
    ' Use bounded context with explicit task context; avoid full-history forks by default. '
    'Use a full-history fork only when needed to convey context reliably, respecting native '
    'tool and user rules.'
)


class CanonicalGuides(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)

    def cli(self, app, operation='update', *options, expected=0):
        result = subprocess.run(['bash', str(ROOT / 'agent-docs.sh'), operation, str(app), *options, '--json'],
                                env={**os.environ, 'PYTHONDONTWRITEBYTECODE': '1'},
                                capture_output=True, text=True)
        self.assertEqual(expected, result.returncode, result.stdout + result.stderr)
        return json.loads(result.stdout)

    def snapshot(self, app):
        return {str(p.relative_to(app)): (p.read_bytes(), p.stat().st_mtime_ns)
                for p in app.rglob('*') if p.is_file()}

    def legacy(self, framework):
        app = self.work / framework / 'example_app'
        app.mkdir(parents=True)
        with gzip.open(ROOT / 'test/fixtures/agent-docs-legacy' / (framework + '.json.gz'), 'rt') as fixture:
            files = json.load(fixture)
        for name, contents in files.items():
            path = app / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(contents)
        return app

    def assert_canonical(self, app, framework):
        modules = [p.name for p in (ROOT / TEMPLATES[framework] / '.claude').glob('*.md')]
        manifest = json.loads((app / '.agent-docs-manifest.json').read_text())
        for module in modules:
            with self.subTest(module=module):
                self.assertTrue((app / '.docs' / module).is_file())
                self.assertIn('.docs/' + module, manifest['template_files'])
                for old in ('.claude/' + module, 'doc/' + module):
                    self.assertFalse((app / old).exists(), old)
                    self.assertNotIn(old, manifest['files'])
        for name in ('AGENTS.md', 'CLAUDE.md'):
            text = (app / name).read_text()
            self.assertIn('.docs/', text)
            self.assertNotRegex(text, r'(?:\.claude|(?<!\.)doc)/[^/\s`\)]+\.md')
        for path in (app / '.docs').glob('*.md'):
            if path.name not in ('project-guidance.md', 'agent-workflow.md'):
                self.assertNotRegex(path.read_text(), r'(?:\.claude|(?<!\.)doc)/[^/\s`\)]+\.md')
        self.assertTrue((app / '.claude/settings.json').is_file())
        self.assertEqual(5, len(list((app / '.claude/agents').glob('workflow-*.md'))))

    def test_template_modules_cannot_claim_reserved_shared_guidance(self):
        bundle = self.work / 'bundle'
        bundle.mkdir()
        for name in ('scripts', *TEMPLATES.values()):
            shutil.copytree(ROOT / name, bundle / name)
        for path in ROOT.glob('*.sh'):
            shutil.copy2(path, bundle / path.name)
        for reserved in ('project-guidance.md', 'agent-workflow.md'):
            with self.subTest(reserved=reserved):
                source = bundle / 'app-template/.claude' / reserved
                source.write_text('A template must not replace shared workflow or app rules.\n')
                app = self.work / reserved
                (app / '.docs').mkdir(parents=True)
                (app / '.docs/project-guidance.md').write_text('Application constraints.\n')
                before = self.snapshot(app)
                result = subprocess.run(['bash', str(bundle / 'agent-docs.sh'), 'update', str(app),
                                         '--framework', 'phoenix', '--json'], capture_output=True, text=True)
                self.assertEqual(2, result.returncode, result.stdout + result.stderr)
                self.assertEqual(before, self.snapshot(app))
                source.unlink()

    def test_fresh_all_frameworks_generate_only_canonical_shared_guides(self):
        for framework in FRAMEWORKS:
            with self.subTest(framework=framework):
                app = self.work / framework
                app.mkdir()
                self.cli(app, 'update', '--framework', framework)
                self.assert_canonical(app, framework)
                before = self.snapshot(app)
                self.cli(app)
                self.assertEqual(before, self.snapshot(app))

    def test_known_managed_legacy_guides_migrate_with_readonly_preview(self):
        for framework in FRAMEWORKS:
            with self.subTest(framework=framework):
                app = self.legacy(framework)
                (app / '.docs/project-guidance.md').write_text('Keep local project constraints.\n')
                before = self.snapshot(app)
                self.cli(app, 'check', expected=1)
                self.cli(app, 'diff', expected=1)
                self.assertEqual(before, self.snapshot(app))
                self.cli(app)
                self.assert_canonical(app, framework)
                self.assertEqual('Keep local project constraints.\n', (app / '.docs/project-guidance.md').read_text())
                for name, (contents, _) in before.items():
                    if name == '.codex/hooks/workflow-manifest.json':
                        old_manifest = json.loads(contents)
                        current_manifest = json.loads((app / name).read_text())
                        self.assertEqual(set(old_manifest), set(current_manifest))
                        self.assertEqual(old_manifest['version'], current_manifest['version'])
                        self.assertEqual('0.4.0', old_manifest['installer']['version'])
                        self.assertEqual('0.4.1', current_manifest['installer']['version'])
                        self.assertRegex(current_manifest['installer']['source_commit'], r'^[0-9a-f]{40,64}$')
                        self.assertEqual(set(old_manifest['sha256']) - {'.claude/testing.md'},
                                         set(current_manifest['sha256']))
                        for tracked, expected_hash in current_manifest['sha256'].items():
                            self.assertEqual(expected_hash, hashlib.sha256((app / tracked).read_bytes()).hexdigest(), tracked)
                        continue
                    if name.startswith(('.claude/agents/', '.claude/hooks/', '.codex/')) or name == '.claude/settings.json':
                        expected = contents
                        if framework in ('sinatra', 'phoenix') and name in ('.codex/hooks/policy.json', '.claude/hooks/policy.json'):
                            expected_policy = json.loads(contents)
                            expected_policy['test_globs'].append('features/**')
                            expected_policy['source_globs'].append('bin/check-features')
                            self.assertEqual(expected_policy, json.loads((app / name).read_text()), name)
                            continue
                        if name in ('.codex/agents/workflow_reviewer.toml', '.claude/agents/workflow-reviewer.md'):
                            expected = expected.replace(b'never bypass them.',
                                                        b'never bypass them.' + REVIEWER_PR_EVIDENCE.encode())
                        if name.startswith(('.codex/agents/workflow_', '.claude/agents/workflow-')):
                            anchor = b'The orchestrator coordinates delegation for this workflow.'
                            self.assertEqual(1, expected.count(anchor), name)
                            addition = COMPACT_COORDINATION
                            if name in ('.codex/agents/workflow_runner.toml', '.claude/agents/workflow-runner.md',
                                        '.codex/agents/workflow_reviewer.toml', '.claude/agents/workflow-reviewer.md'):
                                addition += FULL_EVIDENCE
                            if name in ('.codex/agents/workflow_orchestrator.toml', '.claude/agents/workflow-orchestrator.md'):
                                addition += ORCHESTRATOR_COORDINATION
                            expected = expected.replace(anchor, anchor + addition.encode())
                            if name == '.codex/agents/workflow_orchestrator.toml':
                                self.assertTrue(expected.endswith(b'"\n'), name)
                                expected = expected[:-2] + CODEX_BOUNDED_CONTEXT.encode() + b'"\n'
                        if name.endswith(".md"):
                            expected = expected.replace(b"`.claude/` detail docs", b"`.docs/` detail docs")
                            for module in (ROOT / TEMPLATES[framework] / ".claude").glob("*.md"):
                                expected = expected.replace((".claude/" + module.name).encode(), (".docs/" + module.name).encode())
                                expected = expected.replace(("doc/" + module.name).encode(), (".docs/" + module.name).encode())
                        self.assertEqual(expected, (app / name).read_bytes(), name)
                migrated = self.snapshot(app)
                self.cli(app)
                self.assertEqual(migrated, self.snapshot(app))

    def test_edited_legacy_guide_blocks_every_write(self):
        for framework in FRAMEWORKS:
            for legacy_dir in ('doc', '.claude'):
                with self.subTest(framework=framework, legacy_dir=legacy_dir):
                    app = self.legacy(framework)
                    guide = next((app / legacy_dir).glob('*.md'))
                    guide.write_text(guide.read_text() + '\nLocal rule must survive.\n')
                    before = self.snapshot(app)
                    self.cli(app, expected=2)
                    self.assertEqual(before, self.snapshot(app))
                    shutil.rmtree(app)

    def test_fresh_unmanaged_canonical_guide_blocks_before_any_write(self):
        for framework in FRAMEWORKS:
            with self.subTest(framework=framework):
                app = self.work / framework
                (app / '.docs').mkdir(parents=True)
                module = next((ROOT / TEMPLATES[framework] / '.claude').glob('*.md')).name
                (app / '.docs' / module).write_text('Local app-owned supporting rules.\n')
                before = self.snapshot(app)
                self.cli(app, 'update', '--framework', framework, expected=2)
                self.assertEqual(before, self.snapshot(app))

    def test_unmanaged_canonical_destination_blocks_even_identical_content(self):
        for framework in FRAMEWORKS:
            for identical in (False, True):
                with self.subTest(framework=framework, identical=identical):
                    app = self.legacy(framework)
                    guide = next((app / 'doc').glob('*.md'))
                    target = app / '.docs' / guide.name
                    target.write_text(guide.read_text() if identical else 'Unmanaged app-owned rules.\n')
                    before = self.snapshot(app)
                    self.cli(app, expected=2)
                    self.assertEqual(before, self.snapshot(app))
                    # Reuse the framework name for the next independent fixture.
                    shutil.rmtree(app)


if __name__ == '__main__':
    unittest.main()
