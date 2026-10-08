"""Public agent-document lifecycle: real filesystem contracts, offline only."""
import fnmatch
import gzip
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
        for item in ('scripts', 'app-template', 'app-template-ruby', 'app-template-rails', 'app-template-zola', 'app-template-react'):
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
        for framework, app_type in [('phoenix', 'service'), ('sinatra', 'service'), ('rails', 'service'), ('zola', 'service'), ('react', 'service'),
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

    def test_infers_react_without_misclassifying_typescript_cli(self):
        for framework, dependencies in [('react', {'react': '^19.0.0', 'react-dom': '^19.0.0'}),
                                        ('ts-cli', {})]:
            with self.subTest(framework=framework):
                app = self.work / framework
                app.mkdir()
                (app / 'package.json').write_text(json.dumps({
                    'name': framework, 'dependencies': dependencies,
                    'devDependencies': {'typescript': '^5.0.0'},
                }))
                self.command('update', app=app)
                manifest = json.loads((app / '.agent-docs-manifest.json').read_text())
                self.assertEqual(framework, manifest['framework'])
                self.assertEqual('service' if framework == 'react' else 'cli', manifest['app_type'])
                self.assertEqual('current', self.command('check', app=app)['status'])

    def test_rails_guidance_uses_rails_conventions(self):
        self.install('rails')
        for entrypoint in ('AGENTS.md', 'CLAUDE.md'):
            with self.subTest(entrypoint=entrypoint):
                guide = (self.app / entrypoint).read_text()
                self.assertIn('Rails', guide)
                self.assertIn('Active Record', guide)
                self.assertIn('bin/check', guide)
                self.assertNotIn('Sinatra', guide)
                self.assertNotIn('Sequel', guide)
        testing = (self.app / '.docs/testing.md').read_text()
        for requirement in ('RSpec', 'Cucumber', 'SimpleCov', 'RuboCop', 'data-testid',
                            '100', 'major', 'failure', 'authorization', 'isolation'):
            self.assertIn(requirement, testing)
        for path in ('.docs/architecture-decisions.md', '.docs/separation-of-concerns.md',
                     '.docs/database.md'):
            self.assertTrue((self.app / path).is_file(), path)
        before = self.snapshot()
        self.assertEqual('current', self.command('check')['status'])
        self.command('update')
        self.assertEqual(before, self.snapshot())

    def test_elixir_guidance_requires_executable_meaningful_doctests(self):
        requirements = {
            'representative valid inputs': r'representative valid inputs',
            'intended result': r'assert (?:its|the|their) intended result',
            'happy path': r'at least one happy-path example',
            'fallback examples are insufficient':
                r'nil, empty-input, fallback, or error examples alone are insufficient',
            'satisfied predicates': r'input that satisfies the predicate',
            'both time outcomes': r'valid inputs on both sides of the time condition',
            'stable time examples': r'stable clock or generous relative offsets',
            'additional edge cases': r'edge cases as additional examples',
            'ExUnit registration': r'registered with `doctest` in an ExUnit test',
            'execution': r'run those tests',
            'iex blocks do not execute themselves':
                r'`iex>` block alone does not make an example execute',
            'constant fallback check': r'always returns the fallback value would still pass',
            'setup rules': r'project rules for functions requiring database or external-service setup',
            'successful behavior with setup': r'cover their successful behavior with appropriate tests',
            'project-wide inventory': r'Inventory `@doc` and `@moduledoc` `iex>` examples across the project',
            'every module registered': r'every module containing doctests is registered with `doctest` in ExUnit',
            'normal suite and CI execution': r'Run all doctests through the normal `mix test` suite, including CI',
            'no skipped or excluded registrations':
                r'do not leave registrations skipped, excluded, filtered out, or confined to a separate command',
            'verify actual execution':
                r'Verify actual execution of all doctests in the normal suite; registration alone is insufficient',
        }
        for framework in ('phoenix', 'mix', 'escript'):
            app = self.work / framework
            app.mkdir()
            self.install(framework, app=app)
            paths = ['.docs/agent-workflow.md']
            if framework == 'phoenix':
                paths.extend(['AGENTS.md', 'CLAUDE.md'])
            for path in paths:
                guidance = ' '.join((app / path).read_text().split())
                for requirement, pattern in requirements.items():
                    with self.subTest(framework=framework, path=path, requirement=requirement):
                        self.assertRegex(guidance, pattern)
            with self.subTest(framework=framework, requirement='language scope'):
                workflow = ' '.join((app / '.docs/agent-workflow.md').read_text().split())
                self.assertRegex(workflow, r'For Elixir projects, doctests must')

    def test_rails_workflow_requires_honest_pull_request_test_evidence(self):
        self.install('rails')
        workflow = (self.app / '.docs/agent-workflow.md').read_text()
        self.assertIn('## Pull request test evidence', workflow)
        section = workflow.split('## Pull request test evidence', 1)[1].split('\n## ', 1)[0]
        section = ' '.join(section.split())
        requirements = {
            'every PR': r'(?i)every (?:PR|pull request)',
            'relevant Cucumber specs': r'(?i)relevant.*Cucumber',
            'feature and scenario names': r'(?i)feature.*scenario.*names',
            'Gherkin evidence': r'Gherkin',
            'readable Cucumber evidence': r'(?i)(?:scenario|Gherkin).*content|executed scenario output',
            'names and links are insufficient': r'(?i)names or links alone are insufficient',
            'actual RSpec command': r'bundle exec rspec <relevant spec paths> --format documentation',
            'actual output': r'(?i)actual.*output',
            'commands and results': r'(?i)commands?.*results?',
            'failures reported': r'(?i)failures',
            'skipped reported': r'(?i)skipp(?:ed|ing)',
            'pending reported': r'(?i)pending',
            'explicit applicability explanation': r'(?i)N/A.*reason',
            'missing mandatory tooling is a defect': r'(?i)mandatory tooling missing.*fresh generated project.*defect.*not N/A',
            'Ruby acceptance command': r'bundle exec cucumber --format pretty --strict',
            'focused ExUnit output': r'mix test <relevant test paths> --trace',
            'Elixir acceptance output': r'MIX_ENV=test mix cucumber --format pretty --strict',
            'full gates retained': r'(?i)full.*(?:checks|gates|suite)',
            'no fabricated passing evidence': r'(?i)(?:never|do not).*fabricat',
        }
        for requirement, pattern in requirements.items():
            with self.subTest(requirement=requirement):
                self.assertRegex(section, pattern)
        for path in ('.codex/agents/workflow_reviewer.toml', '.claude/agents/workflow-reviewer.md'):
            with self.subTest(reviewer=path):
                instructions = (self.app / path).read_text()
                if path.endswith('.toml'):
                    instructions = tomllib.loads(instructions)['developer_instructions']
                self.assertIn('.docs/agent-workflow.md#pull-request-test-evidence', instructions)
                self.assertIn('Cucumber', instructions)
                self.assertIn('RSpec', instructions)
                self.assertIn('--format documentation', instructions)
                self.assertIn('Cucumberex', instructions)
                self.assertIn('ExUnit --trace', instructions)
                self.assertIn('Mandatory tooling missing from a fresh generated project is a defect, not N/A.', instructions)
        before = self.snapshot(mtimes=True)
        self.command('update')
        self.assertEqual(before, self.snapshot(mtimes=True))
        self.assertEqual('current', self.command('check')['status'])

    def test_existing_rails_installation_gains_pull_request_evidence_without_losing_local_rules(self):
        fixture = ROOT / 'test/fixtures/agent-docs-legacy/rails.json.gz'
        with gzip.open(fixture, 'rt') as source:
            for name, contents in json.load(source).items():
                path = self.app / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(contents)
        (self.app / '.docs/project-guidance.md').write_text('Keep application-specific constraints.\n')
        self.command('update')
        self.assertIn('## Pull request test evidence', (self.app / '.docs/agent-workflow.md').read_text())
        for path in ('.codex/agents/workflow_reviewer.toml', '.claude/agents/workflow-reviewer.md'):
            self.assertIn('.docs/agent-workflow.md#pull-request-test-evidence', (self.app / path).read_text())
        self.assertEqual('Keep application-specific constraints.\n', (self.app / '.docs/project-guidance.md').read_text())
        before = self.snapshot(mtimes=True)
        self.command('update')
        self.assertEqual(before, self.snapshot(mtimes=True))

    def test_every_framework_requires_dead_code_review_for_each_pr(self):
        requirements = {
            'every PR': 'Every PR must include a dead-code review',
            'usage evidence': 'Check references and dynamic, configuration, framework, and public entry points',
            'test-only references': 'Test-only references do not prove code is live or dead',
            'grep absence': 'Grep absence alone does not prove code is unused',
            'external callers': 'Account for external public API consumers',
            'remove confirmed dead code': 'Delete confirmed dead code',
            'propose exclusive test removal':
                'Propose removing tests that exclusively exercise the removed behavior',
            'concrete proposed diff':
                'Present a concrete unapplied diff with test file paths and deletion hunks',
            'explain obsolete tests': 'explain why each proposed test removal is obsolete',
            'human approval': 'Obtain explicit user approval before deleting tests',
            'review is not human approval': 'Reviewer approval does not substitute for user approval',
            'pending approval': 'Keep tests unchanged while approval is pending',
            'roles and hooks remain': 'Approval preserves source/test role ownership and hook restrictions',
            'approved patch application': 'spec writer applies only the approved test-removal patch when permitted',
            'blocked patch': 'If deletion remains blocked, present the exact patch and blocker',
            'no bypass': 'Never use an alternate editing route or bypass hooks',
            'no false completion': 'Do not claim green tests or commit cleanup that leaves tests failing',
            'retain live behavior coverage': 'Preserve or adapt tests for live behavior, including mixed coverage',
            'do not hide failures': 'Never delete failing tests merely to make the suite pass',
            'source ownership': 'implementer removes source',
            'test ownership': 'spec writer removes or adapts tests',
            'contract approval': 'reviewer approves the changed test contract',
            'validation': 'Run the affected test suite',
            'PR evidence':
                'PR description must record the removed code and tests, or state that no dead code was found',
        }
        for framework in ('phoenix', 'mix', 'escript', 'sinatra', 'zola', 'ruby-cli', 'bash-cli', 'ts-cli'):
            app = self.work / framework
            app.mkdir()
            self.install(framework, app=app)
            workflow = ' '.join((app / '.docs/agent-workflow.md').read_text().split())
            for requirement, clause in requirements.items():
                with self.subTest(framework=framework, requirement=requirement):
                    self.assertIn(clause, workflow)
            for path in ('.codex/agents/workflow_reviewer.toml', '.claude/agents/workflow-reviewer.md'):
                with self.subTest(framework=framework, reviewer=path):
                    instructions = (app / path).read_text()
                    if path.endswith('.toml'):
                        instructions = tomllib.loads(instructions)['developer_instructions']
                    self.assertIn(requirements['every PR'], instructions)
                    self.assertIn(requirements['human approval'], instructions)
                    self.assertIn('.docs/agent-workflow.md#dead-code-review', instructions)

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
        self.assertTrue((self.app / '.docs/payment-integration.md').exists())
        self.command('configure', '--skip-module', 'payment-integration.md', '--skip-agent', 'test-writer.md', '--no-setup')
        for rel in ('.docs/payment-integration.md', '.claude/payment-integration.md',
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
        self.assertTrue((self.app / '.docs/payment-integration.md').exists())
        self.assertTrue((self.app / 'doc/hooks/cloud-setup.sh').exists())

    def test_managed_drift_blocks_update_and_deselection_before_any_write(self):
        self.install()
        path = self.app / '.docs/payment-integration.md'
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
        self.assertIn('New shared billing guidance.', (self.app / '.docs/payment-integration.md').read_text())
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

    def test_rails_policies_own_acceptance_features_and_coverage_harness_as_tests(self):
        self.install('rails')
        harness = ('features/notes.feature', 'features/step_definitions/notes_steps.rb',
                   'features/support/env.rb', 'support/coverage.rb', 'script/coverage.rb',
                   'spec/requests/notes_spec.rb')
        production = ('app/services/notes/create.rb', 'app/support/events.rb',
                      'lib/services/export.rb', 'support/runtime.rb', 'script/deploy.rb')
        for platform in ('codex', 'claude'):
            policy = json.loads((self.app / f'.{platform}/hooks/policy.json').read_text())
            for path in harness:
                with self.subTest(platform=platform, test=path):
                    self.assertTrue(any(fnmatch.fnmatchcase(path, pattern)
                                        for pattern in policy['test_globs']), path)
            for path in production:
                with self.subTest(platform=platform, source=path):
                    self.assertFalse(any(fnmatch.fnmatchcase(path, pattern)
                                         for pattern in policy['test_globs']), path)
                    self.assertTrue(any(fnmatch.fnmatchcase(path, pattern)
                                        for pattern in policy['source_globs']), path)
        # Rails coverage helpers remain specific to Rails.
        sinatra = self.work / 'sinatra_policy'
        sinatra.mkdir()
        self.install('sinatra', app=sinatra)
        policy = json.loads((sinatra / '.codex/hooks/policy.json').read_text())
        for path in harness[3:5]:
            with self.subTest(framework='sinatra', path=path):
                self.assertFalse(any(fnmatch.fnmatchcase(path, pattern)
                                     for pattern in policy['test_globs']), path)

    def test_mandatory_acceptance_features_are_tests_on_both_platforms(self):
        for framework in ('sinatra', 'phoenix', 'escript', 'mix'):
            app = self.work / framework
            app.mkdir()
            self.install(framework, app=app)
            extension = 'rb' if framework == 'sinatra' else 'ex'
            for platform in ('codex', 'claude'):
                policy = json.loads((app / f'.{platform}/hooks/policy.json').read_text())
                for path in ('features/behavior.feature', f'features/step_definitions/steps.{extension}',
                             f'features/support/env.{extension}'):
                    with self.subTest(framework=framework, platform=platform, test=path):
                        self.assertTrue(any(fnmatch.fnmatchcase(path, pattern)
                                            for pattern in policy['test_globs']), path)
                for path in (f'lib/runtime.{extension}', f'lib/support/events.{extension}'):
                    with self.subTest(framework=framework, platform=platform, source=path):
                        self.assertFalse(any(fnmatch.fnmatchcase(path, pattern)
                                             for pattern in policy['test_globs']), path)
                        self.assertTrue(any(fnmatch.fnmatchcase(path, pattern)
                                            for pattern in policy['source_globs']), path)
                self.assertFalse(any(fnmatch.fnmatchcase('bin/check-features', pattern)
                                     for pattern in policy['test_globs']))
                self.assertTrue(any(fnmatch.fnmatchcase('bin/check-features', pattern)
                                    for pattern in policy['source_globs']))
                self.assertFalse(any(fnmatch.fnmatchcase('bin/unrelated-command', pattern)
                                     for pattern in policy['source_globs']))

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
