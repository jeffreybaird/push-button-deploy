"""Public agent-document lifecycle: real filesystem contracts, offline only."""
import fnmatch
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import tomllib
import unittest

ROOT = Path(__file__).resolve().parents[2]
ENV = {**os.environ, 'PYTHONDONTWRITEBYTECODE': '1', 'GIT_CONFIG_GLOBAL': '/dev/null',
       'GIT_CONFIG_NOSYSTEM': '1'}


class Lifecycle(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.work = Path(self.tmp.name).resolve()
        self.app = self.work / 'arbitrary app name'
        self.app.mkdir()

    def command(self, operation, *options, expected=0, root=ROOT, app=None, json_output=True):
        args = ['bash', str(root / 'agent-docs.sh'), operation, str(app or self.app), *options]
        if json_output:
            args.append('--json')
        result = subprocess.run(args, env=ENV, cwd=self.work, text=True, capture_output=True)
        self.assertEqual(expected, result.returncode, result.stdout + result.stderr)
        if json_output:
            payload = json.loads(result.stdout)
            self.assertEqual('UNKNOWN', payload['native_activation'])
            return payload
        return result.stdout

    def snapshot(self, root=None, mtimes=False):
        root = root or self.app
        return {str(p.relative_to(root)): (p.read_bytes(), p.stat().st_mtime_ns) if mtimes else p.read_bytes()
                for p in root.rglob('*') if p.is_file() and not p.is_symlink()}

    def install(self, framework='phoenix', **kwargs):
        return self.command('update', '--framework', framework, **kwargs)

    def bundle(self):
        dest = self.work / 'relocated tool bundle'
        dest.mkdir()
        for item in ('scripts', 'app-template', 'app-template-ruby', 'app-template-rails', 'app-template-zola'):
            shutil.copytree(ROOT / item, dest / item, ignore=shutil.ignore_patterns('__pycache__', '*.pyc'))
        for item in ROOT.glob('*.sh'):
            shutil.copy2(item, dest / item.name)
        return dest

    def test_missing_previews_are_read_only_and_explain_generated_changes(self):
        (self.app / 'README.md').write_text('App owned\n')
        before = self.snapshot(mtimes=True)
        self.assertEqual('missing', self.command('check', '--framework', 'phoenix', expected=1)['status'])
        preview = self.command('diff', '--framework', 'phoenix', expected=1, json_output=False)
        self.assertIn('+++', preview)
        self.assertIn('AGENTS.md', preview)
        self.assertEqual(before, self.snapshot(mtimes=True))

    def test_every_framework_installs_both_native_roles_and_app_owned_guidance(self):
        for framework, app_type in [('phoenix', 'service'), ('sinatra', 'service'), ('rails', 'service'), ('zola', 'service'),
                                    ('escript', 'cli'), ('ruby-cli', 'cli'), ('bash-cli', 'cli'),
                                    ('ts-cli', 'cli'), ('mix', 'library')]:
            with self.subTest(framework=framework):
                app = self.work / framework
                app.mkdir()
                self.install(framework, app=app)
                manifest = json.loads((app / '.agent-docs-manifest.json').read_text())
                self.assertEqual(framework, manifest['framework'])
                self.assertEqual(app_type, manifest['app_type'])
                for path in ['AGENTS.md', 'CLAUDE.md', '.docs/project-guidance.md',
                             '.docs/agent-workflow.md', '.codex/hooks.json', '.claude/settings.json',
                             '.codex/hooks/policy.json', '.claude/hooks/policy.json']:
                    self.assertTrue((app / path).is_file(), path)
                self.assertEqual(5, len(list((app / '.codex/agents').glob('workflow_*.toml'))))
                self.assertEqual(5, len(list((app / '.claude/agents').glob('workflow-*.md'))))
                for guide in ('AGENTS.md', 'CLAUDE.md'):
                    self.assertIn('.docs/project-guidance.md', (app / guide).read_text())
                self.assertFalse((app / '.git').exists())
                self.assertEqual('current', self.command('check', app=app)['status'])

    def test_rails_guidance_uses_rails_conventions(self):
        self.install('rails')
        for entrypoint in ('AGENTS.md', 'CLAUDE.md'):
            with self.subTest(entrypoint=entrypoint):
                guide = (self.app / entrypoint).read_text()
                self.assertIn('Rails', guide)
                self.assertIn('Active Record', guide)
                self.assertIn('bin/rails test', guide)
                self.assertNotIn('Sinatra', guide)
                self.assertNotIn('Sequel', guide)
        before = self.snapshot()
        self.assertEqual('current', self.command('check')['status'])
        self.command('update')
        self.assertEqual(before, self.snapshot())

    def test_preserves_custom_guidance_settings_and_user_added_hooks(self):
        (self.app / '.docs').mkdir()
        (self.app / '.docs/project-guidance.md').write_text('App-specific constraints.\n')
        for guide in ('AGENTS.md', 'CLAUDE.md'):
            (self.app / guide).write_text('Custom instructions retained verbatim.\n')
        (self.app / '.claude').mkdir()
        custom_hook = {'matcher': 'Read', 'hooks': [{'type': 'command', 'command': 'echo custom'}]}
        settings = {'permissions': {'allow': ['Read']}, 'env': {'CUSTOM': 'yes'},
                    'hooks': {'PreToolUse': [custom_hook]}}
        (self.app / '.claude/settings.json').write_text(json.dumps(settings))
        (self.app / '.codex').mkdir()
        (self.app / '.codex/config.toml').write_text('approval_policy = "on-request"\n[features]\ncustom = true\n')
        self.install()
        for guide in ('AGENTS.md', 'CLAUDE.md'):
            self.assertIn('Custom instructions retained verbatim.', (self.app / guide).read_text())
        settings_after = json.loads((self.app / '.claude/settings.json').read_text())
        self.assertEqual(settings['permissions'], settings_after['permissions'])
        self.assertEqual(settings['env'], settings_after['env'])
        self.assertIn(custom_hook, settings_after['hooks']['PreToolUse'])
        config = tomllib.loads((self.app / '.codex/config.toml').read_text())
        self.assertEqual('on-request', config['approval_policy'])
        self.assertTrue(config['features']['custom'])
        (self.app / '.docs/project-guidance.md').write_text('New app-specific constraint.\n')
        with (self.app / 'AGENTS.md').open('a') as f:
            f.write('\nNew custom instruction outside managed sections.\n')
        settings_after['env']['LATER'] = 'also preserved'
        (self.app / '.claude/settings.json').write_text(json.dumps(settings_after))
        self.assertEqual('current', self.command('check')['status'])
        self.command('update')
        self.assertEqual('New app-specific constraint.\n', (self.app / '.docs/project-guidance.md').read_text())
        self.assertIn('New custom instruction', (self.app / 'AGENTS.md').read_text())
        self.assertEqual('also preserved', json.loads((self.app / '.claude/settings.json').read_text())['env']['LATER'])

    def test_update_and_previews_are_byte_and_mtime_idempotent(self):
        self.install('sinatra')
        before = self.snapshot(mtimes=True)
        self.assertEqual('current', self.command('check')['status'])
        self.command('diff')
        self.command('update')
        self.assertEqual(before, self.snapshot(mtimes=True))

    def test_configure_removes_owned_selection_and_update_preserves_it(self):
        self.install()
        self.assertTrue((self.app / 'doc/payment-integration.md').exists())
        self.command('configure', '--skip-module', 'payment-integration.md', '--skip-agent', 'test-writer.md', '--no-setup')
        for rel in ('doc/payment-integration.md', '.claude/payment-integration.md',
                    'doc/agents/test-writer.md', '.claude/agents/test-writer.md',
                    'doc/hooks/cloud-setup.sh', '.claude/cloud-setup.sh'):
            self.assertFalse((self.app / rel).exists(), rel)
        settings = json.loads((self.app / '.claude/settings.json').read_text())
        self.assertTrue(settings['hooks']['PreToolUse'])
        self.assertFalse(settings['hooks'].get('SessionStart'))
        before = self.snapshot(mtimes=True)
        self.command('update')
        self.assertEqual(before, self.snapshot(mtimes=True))
        self.command('configure', '--all')
        self.assertTrue((self.app / 'doc/payment-integration.md').exists())
        self.assertTrue((self.app / 'doc/hooks/cloud-setup.sh').exists())

    def test_managed_drift_blocks_update_and_deselection_before_any_write(self):
        self.install()
        path = self.app / 'doc/payment-integration.md'
        path.write_text(path.read_text() + '\nCustom edit to managed content\n')
        before = self.snapshot(mtimes=True)
        self.assertEqual('drift', self.command('check', expected=1)['status'])
        self.command('update', expected=2)
        self.command('configure', '--skip-module', 'payment-integration.md', expected=2)
        self.assertEqual(before, self.snapshot(mtimes=True))

    def test_native_hook_drift_blocks_update(self):
        self.install()
        hook = self.app / '.codex/hooks/workflow_guard.py'
        hook.write_text(hook.read_text() + '\n# local edit\n')
        before = self.snapshot(mtimes=True)
        self.command('update', expected=2)
        self.assertEqual(before, self.snapshot(mtimes=True))

    def test_invalid_selection_and_framework_are_preflighted(self):
        self.install()
        before = self.snapshot(mtimes=True)
        for opts in [('--skip-module', '../outside.md'), ('--skip-module', 'unknown.md'),
                     ('--skip-agent', 'unknown.md'), ('--hook', 'unknown'),
                     ('--framework', 'unknown'), ('--app-type', 'library')]:
            with self.subTest(options=opts):
                self.command('configure', *opts, expected=2)
                self.assertEqual(before, self.snapshot(mtimes=True))

    def test_managed_symlinks_and_target_alias_are_rejected_before_writes(self):
        outside = self.work / 'outside'
        outside.mkdir()
        (outside / 'sentinel').write_text('unchanged')
        before_outside = self.snapshot(outside, mtimes=True)
        for rel in ('.docs', '.claude', '.codex', 'doc', 'AGENTS.md', '.agent-docs-manifest.json'):
            with self.subTest(path=rel):
                app = self.work / ('unsafe-' + rel.replace('.', '').replace('/', '-'))
                app.mkdir()
                (app / rel).symlink_to(outside)
                before = self.snapshot(app, mtimes=True)
                self.install(app=app, expected=2)
                self.assertEqual(before, self.snapshot(app, mtimes=True))
                self.assertEqual(before_outside, self.snapshot(outside, mtimes=True))
        alias = self.work / 'alias'
        alias.symlink_to(self.app)
        self.install(app=alias, expected=2)
        self.assertEqual({}, self.snapshot())

    def test_bundle_is_relocatable_no_git_and_ignores_unrelated_changes(self):
        bundle = self.bundle()
        self.install(root=bundle)
        before = self.snapshot(mtimes=True)
        (bundle / 'README.md').write_text('Unrelated change\n')
        (bundle / 'unrelated.tmp').write_text('Untracked data\n')
        self.assertEqual('current', self.command('check', root=bundle)['status'])
        self.command('update', root=bundle)
        self.assertEqual(before, self.snapshot(mtimes=True))
        self.assertFalse(list(bundle.rglob('__pycache__')))

    def test_changed_bundled_guidance_upgrades_without_losing_project_rules(self):
        bundle = self.bundle()
        self.install(root=bundle)
        (self.app / '.docs/project-guidance.md').write_text('Preserve my app rules.\n')
        source = bundle / 'app-template/.claude/payment-integration.md'
        source.write_text(source.read_text() + '\nNew shared billing guidance.\n')
        before = self.snapshot(mtimes=True)
        self.assertEqual('update', self.command('check', root=bundle, expected=1)['status'])
        preview = self.command('diff', root=bundle, expected=1, json_output=False)
        self.assertIn('New shared billing guidance.', preview)
        self.assertEqual(before, self.snapshot(mtimes=True))
        self.command('update', root=bundle)
        self.assertIn('New shared billing guidance.', (self.app / 'doc/payment-integration.md').read_text())
        self.assertEqual('Preserve my app rules.\n', (self.app / '.docs/project-guidance.md').read_text())
        after = self.snapshot(mtimes=True)
        self.command('update', root=bundle)
        self.assertEqual(after, self.snapshot(mtimes=True))

    def test_legacy_public_route_uses_manifest_and_preserves_selection(self):
        self.install()
        self.command('configure', '--skip-module', 'payment-integration.md')
        before = self.snapshot(mtimes=True)
        result = subprocess.run(['bash', str(ROOT / 'claude-docs.sh'), '--all', '--framework', 'phoenix', str(self.app)],
                                cwd=self.work, env=ENV, text=True, capture_output=True)
        self.assertEqual(0, result.returncode, result.stderr + result.stdout)
        self.assertEqual(before, self.snapshot(mtimes=True))

    def test_manifest_cannot_claim_outside_paths(self):
        self.install()
        outside = self.work / 'outside.md'
        outside.write_text('Never modify me.\n')
        manifest_path = self.app / '.agent-docs-manifest.json'
        original = json.loads(manifest_path.read_text())
        for key in ('../outside.md', str(outside), 'doc/../../outside.md'):
            with self.subTest(key=key):
                manifest = json.loads(json.dumps(original))
                manifest['files'][key] = '0' * 64
                manifest_path.write_text(json.dumps(manifest))
                before = self.snapshot(mtimes=True)
                self.command('update', expected=2)
                self.assertEqual(before, self.snapshot(mtimes=True))
                self.assertEqual('Never modify me.\n', outside.read_text())

    def test_modified_native_hook_registration_is_managed_drift(self):
        self.install()
        path = self.app / '.claude/settings.json'
        settings = json.loads(path.read_text())
        commands = [hook for event in settings['hooks'].values() for matcher in event
                    for hook in matcher.get('hooks', []) if 'workflow_guard.py' in hook.get('command', '')]
        self.assertTrue(commands)
        commands[0]['command'] = 'echo bypass'
        path.write_text(json.dumps(settings))
        before = self.snapshot(mtimes=True)
        self.command('update', expected=2)
        self.assertEqual(before, self.snapshot(mtimes=True))

    def test_public_launcher_supports_symlink_and_pbd_root(self):
        bundle = self.bundle()
        link = self.work / 'installed-agent-docs'
        link.symlink_to(bundle / 'agent-docs.sh')
        result = subprocess.run(['bash', str(link), 'update', str(self.app), '--framework', 'bash-cli', '--json'],
                                cwd=self.work, env=ENV, text=True, capture_output=True)
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        before = self.snapshot(mtimes=True)
        isolated = self.work / 'bin'
        isolated.mkdir()
        shutil.copy2(bundle / 'agent-docs.sh', isolated / 'agent-docs')
        result = subprocess.run(['bash', str(isolated / 'agent-docs'), 'check', str(self.app), '--json'],
                                cwd=self.work, env={**ENV, 'PBD_ROOT': str(bundle)}, text=True, capture_output=True)
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertEqual('current', json.loads(result.stdout)['status'])
        self.assertEqual(before, self.snapshot(mtimes=True))

    def test_bootstrap_generation_installs_lifecycle_for_cli_and_library_apps(self):
        script = r"""
set -euo pipefail
SCRIPT_DIR="$1"
APP_DIR="$2"
APP_TYPE="$3"
FRAMEWORK="$4"
DATABASE_BACKEND=none
log() { :; }
warn() { :; }
fail() { printf '%s\n' "$*" >&2; exit 1; }
. "$SCRIPT_DIR/scripts/app-types.sh"
. "$SCRIPT_DIR/scripts/bootstrap/app.sh"
ensure_app
"""
        for framework, app_type in [('escript', 'cli'), ('ruby-cli', 'cli'), ('bash-cli', 'cli'),
                                    ('ts-cli', 'cli'), ('mix', 'library')]:
            with self.subTest(framework=framework):
                app = self.work / ('generated_' + framework.replace('-', '_'))
                result = subprocess.run(['bash', '-c', script, '_', str(ROOT), str(app), app_type, framework],
                                        cwd=self.work, env=ENV, capture_output=True, text=True)
                self.assertEqual(0, result.returncode, result.stdout + result.stderr)
                self.assertTrue((app / '.agent-docs-manifest.json').is_file())
                self.assertEqual('current', self.command('check', app=app)['status'])

    def test_framework_policies_classify_source_tests_and_leave_guidance_unscoped(self):
        examples = {'phoenix': ('lib/app.ex', 'test/app_test.exs'),
                    'sinatra': ('app.rb', 'test/app_test.rb'),
                    'rails': ('app/controllers/health_controller.rb', 'test/integration/health_test.rb'),
                    'zola': ('templates/index.html', 'test/render_test.py'),
                    'escript': ('lib/tool.ex', 'test/tool_test.exs'),
                    'ruby-cli': ('lib/tool.rb', 'test/tool_test.rb'),
                    'bash-cli': ('bin/tool', 'test/tool.sh'),
                    'ts-cli': ('src/index.ts', 'test/index.test.ts'),
                    'mix': ('lib/library.ex', 'test/library_test.exs')}
        for framework, (source, test) in examples.items():
            with self.subTest(framework=framework):
                app = self.work / framework
                app.mkdir()
                self.install(framework, app=app)
                policy = json.loads((app / '.codex/hooks/policy.json').read_text())
                self.assertEqual(policy, json.loads((app / '.claude/hooks/policy.json').read_text()))
                self.assertEqual(2, policy['schema_version'])
                self.assertTrue(any(fnmatch.fnmatchcase(source, glob) for glob in policy['source_globs']), source)
                self.assertTrue(any(fnmatch.fnmatchcase(test, glob) for glob in policy['test_globs']), test)
                for guidance in ('.docs/project-guidance.md', 'README.md', 'lib/notes.md'):
                    self.assertFalse(any(fnmatch.fnmatchcase(guidance, glob)
                                         for glob in policy['source_globs'] + policy['test_globs']), guidance)

    def test_malformed_manifest_or_claimed_unowned_file_rejects_before_writes(self):
        self.install()
        (self.app / 'README.md').write_text('App-owned README.\n')
        path = self.app / '.agent-docs-manifest.json'
        original = json.loads(path.read_text())
        invalid = json.loads(json.dumps(original))
        import hashlib
        invalid['files']['README.md'] = hashlib.sha256((self.app / 'README.md').read_bytes()).hexdigest()
        for content in ('{invalid json', json.dumps(invalid)):
            with self.subTest(content=content[:30]):
                path.write_text(content)
                before = self.snapshot(mtimes=True)
                self.command('update', expected=2)
                self.command('configure', '--all', expected=2)
                self.assertEqual(before, self.snapshot(mtimes=True))


if __name__ == '__main__':
    unittest.main()
