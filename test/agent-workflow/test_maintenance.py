"""Maintenance CLI contract: preview without writes and explicit guarded rollout."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

BASE = Path(__file__).resolve().parents[2] / 'scripts' / 'agent-workflow'
ENV = {**os.environ, 'PYTHONDONTWRITEBYTECODE': '1', 'GIT_OPTIONAL_LOCKS': '0'}


class MaintenanceFixture(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.source = self.root / 'installer source with spaces'
        self.source.mkdir()
        for name in ('installer.py', 'repo_policies.py', 'workflow_guard.py',
                     'workflow_audit.py', 'workflow.py', 'release.json'):
            if (BASE / name).exists():
                shutil.copyfile(BASE / name, self.source / name)
        (self.source / '.gitignore').write_text('__pycache__/\n*.py[cod]\nevidence/\n')
        self.initialize_git(self.source)
        self.commit(self.source)
        self.repos = self.root / 'repositories with spaces'
        self.repos.mkdir()

    def git(self, root, *args):
        return subprocess.run(['git', '-C', str(root), *args], env=ENV, text=True,
                              capture_output=True, check=True).stdout.strip()

    def initialize_git(self, root):
        self.git(root, 'init', '-q')
        # Snapshot assertions include .git: no asynchronous maintenance may
        # create or remove lock/object files after a fixture commit returns.
        self.git(root, 'config', '--local', 'maintenance.auto', 'false')
        self.git(root, 'config', '--local', 'gc.auto', '0')

    def commit(self, root):
        self.git(root, 'add', '-A')
        self.git(root, '-c', 'commit.gpgsign=false', '-c', 'user.name=Fixture',
                 '-c', 'user.email=fixture@example.invalid', 'commit', '-qm', 'fixture')

    def repo(self, name='heybridge'):
        root = self.repos / name
        root.mkdir()
        self.initialize_git(root)
        (root / 'README.md').write_text('Unrelated application file.\n')
        self.commit(root)
        return root

    def cli(self, operation, names=('heybridge',), *extra, json_output=True):
        args = [sys.executable, '-B', str(self.source / 'workflow.py'), operation,
                '--root', str(self.repos)]
        for name in names:
            args += ['--repo', name]
        if json_output:
            args.append('--json')
        return subprocess.run(args + list(extra), env=ENV, text=True, capture_output=True,
                              cwd=self.root)

    def result(self, completed, expected_exit):
        self.assertEqual(expected_exit, completed.returncode, completed.stderr + completed.stdout)
        result = json.loads(completed.stdout)
        self.assertIsInstance(result['repositories'], list)
        for entry in result['repositories']:
            self.assertEqual('UNKNOWN', entry['native_activation'])
        return {entry['name']: entry for entry in result['repositories']}

    def snapshot(self, root):
        # Bytes and mtimes include the Git index and existing configuration.
        return {str(path.relative_to(root)): (path.read_bytes(), path.stat().st_mtime_ns)
                for path in root.rglob('*') if path.is_file() and not path.is_symlink()}

    def installed(self, name='heybridge'):
        root = self.repo(name)
        self.result(self.cli('apply', (name,)), 0)
        self.commit(root)
        return root


class MaintenanceGitIsolation(MaintenanceFixture):
    def test_fixture_commits_cannot_spawn_background_maintenance(self):
        trace = self.root / 'git-trace.jsonl'
        with patch.dict(ENV, {'GIT_TRACE2_EVENT': str(trace)}):
            root = self.repo()
        events = [json.loads(line) for line in trace.read_text().splitlines()]
        background = [event['argv'] for event in events
                      if event.get('event') == 'child_start'
                      and any(command in event.get('argv', []) for command in ('maintenance', 'gc'))]
        self.assertEqual([], background, 'fixture commits must not race full .git snapshots')
        for repository in (self.source, root):
            with self.subTest(repository=repository.name):
                self.assertEqual('false', self.git(repository, 'config', '--local', '--bool',
                                                  '--get', 'maintenance.auto'))
                self.assertEqual('0', self.git(repository, 'config', '--local', '--get', 'gc.auto'))
        before = self.snapshot(root)
        self.result(self.cli('check'), 1)
        self.result(self.cli('diff'), 1)
        self.assertEqual(before, self.snapshot(root))


class MaintenanceCLI(MaintenanceFixture):
    def test_check_and_diff_missing_harness_do_not_create_or_modify_files(self):
        root = self.repo()
        before = self.snapshot(root)
        entries = self.result(self.cli('check'), 1)
        self.assertEqual('missing', entries['heybridge']['status'])
        self.assertEqual(before, self.snapshot(root))
        preview = self.cli('diff', json_output=False)
        self.assertEqual(1, preview.returncode, preview.stderr)
        self.assertIn('+++', preview.stdout)
        self.assertIn('.codex/hooks.json', preview.stdout)
        self.assertIn('workflow_guard.py', preview.stdout)
        self.assertEqual(before, self.snapshot(root))

    def test_apply_explicit_selection_preserves_custom_settings_and_unscoped_edits(self):
        root = self.repo()
        (root / 'AGENTS.md').write_text('# Local instructions\nKeep project guidance.\n')
        (root / '.claude').mkdir()
        (root / '.claude/settings.json').write_text(json.dumps({'env': {'CUSTOM': 'keep'}}))
        self.commit(root)
        (root / 'README.md').write_text('Unstaged application documentation.\n')
        entries = self.result(self.cli('apply'), 0)
        self.assertEqual('current', entries['heybridge']['status'])
        self.assertIn('Keep project guidance.', (root / 'AGENTS.md').read_text())
        self.assertEqual({'CUSTOM': 'keep'}, json.loads(
            (root / '.claude/settings.json').read_text())['env'])
        self.assertEqual('Unstaged application documentation.\n', (root / 'README.md').read_text())
        preview_before = self.snapshot(root)
        self.assertEqual('current', self.result(self.cli('check'), 0)['heybridge']['status'])
        self.result(self.cli('diff'), 0)
        self.assertEqual(preview_before, self.snapshot(root))
        self.commit(root)
        self.result(self.cli('apply'), 0)
        # Compare managed/application bytes after committing, rather than Git commit metadata.
        first = self.snapshot(root)
        self.result(self.cli('apply'), 0)
        self.assertEqual({name: data[0] for name, data in first.items()},
                         {name: data[0] for name, data in self.snapshot(root).items()})

    def test_check_and_diff_report_manifest_drift_without_writes(self):
        root = self.installed()
        target = root / '.codex/hooks/workflow_guard.py'
        target.write_text(target.read_text() + '\n# local edit\n')
        before = self.snapshot(root)
        self.assertEqual('drift', self.result(self.cli('check'), 1)['heybridge']['status'])
        self.result(self.cli('diff'), 1)
        self.assertEqual(before, self.snapshot(root))

    def test_apply_preflights_all_selected_before_writing(self):
        first = self.repo('heybridge')
        second = self.installed('rode')
        target = second / '.codex/hooks/workflow_guard.py'
        target.write_text(target.read_text() + '\n# local edit\n')
        before = self.snapshot(self.repos)
        self.result(self.cli('apply', ('heybridge', 'rode')), 2)
        self.assertEqual(before, self.snapshot(self.repos))
        self.assertFalse((first / '.codex').exists())

    def test_apply_rejects_managed_git_edits_even_with_refreshed_manifest(self):
        root = self.installed()
        target = root / '.codex/hooks/workflow_guard.py'
        manifest_path = root / '.codex/hooks/workflow-manifest.json'
        for staged in (False, True):
            with self.subTest(staged=staged):
                target.write_text(target.read_text() + '\n# accepted locally but uncommitted\n')
                manifest = json.loads(manifest_path.read_text())
                manifest['sha256']['.codex/hooks/workflow_guard.py'] = hashlib.sha256(target.read_bytes()).hexdigest()
                manifest_path.write_text(json.dumps(manifest))
                if staged:
                    self.git(root, 'add', '.codex/hooks/workflow_guard.py',
                             '.codex/hooks/workflow-manifest.json')
                before = self.snapshot(root)
                self.result(self.cli('apply'), 2)
                self.assertEqual(before, self.snapshot(root))
                self.git(root, 'reset', '--hard', '-q', 'HEAD')
        fresh = self.repo('rode')
        (fresh / '.codex').mkdir()
        (fresh / '.codex/hooks.json').write_text('{}')
        before = self.snapshot(fresh)
        self.result(self.cli('apply', ('rode',)), 2)
        self.assertEqual(before, self.snapshot(fresh))
        (fresh / '.gitignore').write_text('.codex/\n')
        self.commit(fresh)
        self.assertEqual('.codex/hooks.json', self.git(fresh, 'ls-files', '--others', '--ignored',
                                                      '--exclude-standard', '.codex/hooks.json'))
        before = self.snapshot(fresh)
        self.result(self.cli('apply', ('rode',)), 2)
        self.assertEqual(before, self.snapshot(fresh))

    def test_unknown_missing_and_unselected_targets_are_rejected_without_writes(self):
        self.repo()
        for names in (('unknown_repo',), ('../heybridge',), ('rode',), ()):
            with self.subTest(names=names):
                before = self.snapshot(self.repos)
                self.result(self.cli('apply', names), 2)
                self.assertEqual(before, self.snapshot(self.repos))

    def test_symlink_target_and_managed_destination_are_rejected(self):
        root = self.repo()
        outside = self.root / 'outside'
        outside.mkdir()
        (outside / 'keep').write_text('untouched')
        (self.repos / 'rode').symlink_to(outside, target_is_directory=True)
        before = self.snapshot(outside)
        targets_before = self.snapshot(self.repos)
        self.result(self.cli('apply', ('heybridge', 'rode')), 2)
        self.assertEqual(targets_before, self.snapshot(self.repos))
        self.assertFalse((root / '.codex').exists())
        self.assertEqual(before, self.snapshot(outside))
        (root / '.codex').symlink_to(outside, target_is_directory=True)
        self.result(self.cli('check'), 2)
        self.result(self.cli('apply'), 2)
        self.assertEqual(before, self.snapshot(outside))

    def test_manifest_path_keys_cannot_escape_or_claim_unmanaged_files(self):
        root = self.installed()
        path = root / '.codex/hooks/workflow-manifest.json'
        original = path.read_bytes()
        for malicious in ('../../outside', '/tmp/outside', 'README.md'):
            with self.subTest(path=malicious):
                manifest = json.loads(original)
                manifest['sha256'][malicious] = '0' * 64
                path.write_text(json.dumps(manifest))
                before = self.snapshot(root)
                self.result(self.cli('check'), 2)
                self.result(self.cli('apply'), 2)
                self.assertEqual(before, self.snapshot(root))
        for malformed in (None, [], 'hashes', {'.codex/hooks/workflow_guard.py': 12},
                          {'.codex/hooks/workflow_guard.py': 'invalid digest'}):
            with self.subTest(sha256=malformed):
                manifest = json.loads(original)
                manifest['sha256'] = malformed
                path.write_text(json.dumps(manifest))
                before = self.snapshot(root)
                for operation in ('check', 'apply'):
                    completed = self.cli(operation)
                    self.result(completed, 2)
                    self.assertNotIn('Traceback', completed.stderr + completed.stdout)
                self.assertEqual(before, self.snapshot(root))

        path.write_bytes(original)
        malformed_hooks = root / '.codex/hooks.json'
        malformed_hooks.write_text(json.dumps({'hooks': {'PreToolUse': [{'hooks': ['invalid']}]}}))
        fresh = self.repo('rode')
        before = self.snapshot(self.repos)
        for operation in ('check', 'apply'):
            completed = self.cli(operation, ('rode', 'heybridge'))
            self.assertNotIn('Traceback', completed.stderr + completed.stdout)
            self.result(completed, 2)
        self.assertEqual(before, self.snapshot(self.repos))
        self.assertFalse((fresh / '.codex').exists())

    def test_all_checks_registered_repository_set_with_no_writes(self):
        spec = importlib.util.spec_from_file_location('maintenance_policies', BASE / 'repo_policies.py')
        policies = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(policies)
        for name in policies.REPO_POLICIES:
            self.repo(name)
        before = self.snapshot(self.repos)
        entries = self.result(self.cli('check', (), '--all'), 1)
        self.assertEqual(set(policies.REPO_POLICIES), set(entries))
        self.assertTrue(all(entry['status'] == 'missing' for entry in entries.values()))
        self.assertEqual(before, self.snapshot(self.repos))
        applied = self.result(self.cli('apply', (), '--all'), 0)
        self.assertEqual(set(policies.REPO_POLICIES), set(applied))
        self.assertTrue(all(entry['status'] == 'current' for entry in applied.values()))
        for name in applied:
            self.assertTrue((self.repos / name / '.codex/hooks/workflow-manifest.json').exists())

    def test_render_is_pure_and_install_api_remains_compatible(self):
        spec = importlib.util.spec_from_file_location('maintenance_installer', BASE / 'installer.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        root = self.repo()
        policy = {'schema_version': 2, 'source_globs': ['src/**'], 'test_globs': ['tests/**']}
        before = self.snapshot(root)
        rendered = module.render(root, policy)
        self.assertIsInstance(rendered['files'], dict)
        self.assertIn('.codex/hooks.json', rendered['files'])
        self.assertEqual([], rendered['report']['previous_drift'])
        self.assertEqual(before, self.snapshot(root))
        report = module.install(root, policy)
        self.assertEqual(rendered['report'], report)
        for name, content in rendered['files'].items():
            self.assertEqual(content, (root / name).read_text())
        stamped = self.installed('rode')
        manifest_path = stamped / '.codex/hooks/workflow-manifest.json'
        provenance = json.loads(manifest_path.read_text())['installer']
        stamped_policy = json.loads((stamped / '.codex/hooks/policy.json').read_text())
        before = self.snapshot(stamped)
        preview = module.render(stamped, stamped_policy)
        self.assertEqual(before, self.snapshot(stamped))
        self.assertEqual(provenance, json.loads(
            preview['files']['.codex/hooks/workflow-manifest.json'])['installer'])
        module.install(stamped, stamped_policy)
        self.assertEqual(provenance, json.loads(manifest_path.read_text())['installer'])


class LifecycleOwnership(MaintenanceFixture):
    def test_registered_cli_refuses_lifecycle_owned_target_without_writes(self):
        root = self.installed()
        (root / '.agent-docs-manifest.json').write_text('{"schema_version": 1}\n')
        before = self.snapshot(root)
        for operation in ('check', 'diff', 'apply'):
            with self.subTest(operation=operation):
                result = self.cli(operation)
                self.result(result, 2)
                self.assertIn('agent-docs.sh', result.stdout + result.stderr)
                self.assertEqual(before, self.snapshot(root))


class InstallerProvenance(MaintenanceFixture):
    # Reuse fixture helpers; only provenance cases are collected in this class.
    def test_release_and_manifest_identify_installer_component_content(self):
        release = json.loads((self.source / 'release.json').read_text())
        self.assertEqual('0.3.1', release['installer_version'])
        root = self.installed()
        manifest = json.loads((root / '.codex/hooks/workflow-manifest.json').read_text())
        self.assertEqual(release['installer_version'], manifest['installer']['version'])
        self.assertRegex(manifest['installer']['source_commit'], r'^[0-9a-f]{64}$')
        report = json.loads(self.cli('check').stdout)
        self.assertEqual(False, report['installer']['dirty'])
        self.assertEqual(manifest['installer']['source_commit'], report['installer']['source_commit'])

    def test_old_provenance_requires_update_and_apply_refreshes_it(self):
        root = self.installed()
        path = root / '.codex/hooks/workflow-manifest.json'
        manifest = json.loads(path.read_text())
        manifest['installer'] = {'version': '0.1.0', 'source_commit': '0' * 40}
        path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
        self.commit(root)
        before = self.snapshot(root)
        self.assertEqual('update', self.result(self.cli('check'), 1)['heybridge']['status'])
        self.result(self.cli('diff'), 1)
        self.assertEqual(before, self.snapshot(root))
        self.result(self.cli('apply'), 0)
        self.assertEqual(json.loads(self.cli('check').stdout)['installer']['source_commit'],
                         json.loads(path.read_text())['installer']['source_commit'])

    def test_component_updates_apply_without_source_git_or_clean_checkout(self):
        root = self.installed()
        initial = json.loads(self.cli('check').stdout)['installer']['source_commit']
        path = self.source / 'installer.py'
        path.write_text(path.read_text() + '\n# component update fixture\n')
        before = self.snapshot(root)
        check = self.cli('check')
        self.assertEqual('update', self.result(check, 1)['heybridge']['status'])
        metadata = json.loads(check.stdout)['installer']
        self.assertFalse(metadata['dirty'])
        self.assertNotEqual(initial, metadata['source_commit'])
        self.assertEqual(before, self.snapshot(root))
        shutil.rmtree(self.source / '.git')
        self.result(self.cli('apply'), 0)
        self.assertEqual(metadata['source_commit'], json.loads(self.cli('check').stdout)['installer']['source_commit'])

    def test_unrelated_files_and_git_commits_do_not_change_component_provenance(self):
        root = self.installed()
        initial = json.loads(self.cli('check').stdout)['installer']['source_commit']
        (self.source / 'unrelated.md').write_text('Not part of the workflow component.\n')
        self.result(self.cli('check'), 0)
        self.commit(self.source)
        self.result(self.cli('check'), 0)
        self.assertEqual(initial, json.loads(self.cli('check').stdout)['installer']['source_commit'])
        self.assertEqual('current', self.result(self.cli('check'), 0)['heybridge']['status'])


class HumanStatusHelp(MaintenanceFixture):
    def assert_activation_help(self, text):
        lower = text.lower()
        self.assertIn('native activation unknown', lower)
        for meaning in ('unverified', 'trust', 'invocation', 'integrity'):
            self.assertIn(meaning, lower)
        self.assertIn('MAINTENANCE.md', text)

    def test_human_update_lists_metadata_only_change_and_explains_unknown_after_apply(self):
        root = self.installed()
        path = root / '.codex/hooks/workflow-manifest.json'
        manifest = json.loads(path.read_text())
        manifest['installer'] = {'version': '0.1.0', 'source_commit': '0' * 40}
        path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
        self.commit(root)
        entry = self.result(self.cli('check'), 1)['heybridge']
        self.assertEqual('update', entry['status'])
        self.assertEqual(['.codex/hooks/workflow-manifest.json'], entry['changed_files'])
        self.assertEqual([], entry['drift_files'])
        before = self.snapshot(root)
        completed = self.cli('check', json_output=False)
        self.assertEqual(1, completed.returncode, completed.stderr)
        self.assertEqual(before, self.snapshot(root))
        self.assertIn('changed files', completed.stdout.lower())
        self.assertIn('.codex/hooks/workflow-manifest.json', completed.stdout)
        for meaning in ('update', 'generated', 'content', 'provenance'):
            self.assertIn(meaning, completed.stdout.lower())
        self.assert_activation_help(completed.stdout)
        applied = self.cli('apply', json_output=False)
        self.assertEqual(0, applied.returncode, applied.stderr)
        self.assert_activation_help(applied.stdout)
        current = self.cli('check', json_output=False)
        self.assertEqual(0, current.returncode, current.stderr)
        self.assertIn('heybridge: current', current.stdout)
        self.assert_activation_help(current.stdout)
        self.assertEqual('UNKNOWN', self.result(self.cli('check'), 0)['heybridge']['native_activation'])

    def test_human_drift_lists_affected_file_and_reconciliation_guidance(self):
        root = self.installed()
        path = root / '.codex/hooks/workflow_guard.py'
        path.write_text(path.read_text() + '\n# intentional local edit\n')
        entry = self.result(self.cli('check'), 1)['heybridge']
        self.assertEqual('drift', entry['status'])
        self.assertEqual(['.codex/hooks/workflow_guard.py'], entry['drift_files'])
        before = self.snapshot(root)
        completed = self.cli('check', json_output=False)
        self.assertEqual(1, completed.returncode, completed.stderr)
        self.assertEqual(before, self.snapshot(root))
        self.assertIn('drift files', completed.stdout.lower())
        self.assertIn('.codex/hooks/workflow_guard.py', completed.stdout)
        for action in ('diff', 'reconcile'):
            self.assertIn(action, completed.stdout.lower())
        self.assertIn('MAINTENANCE.md', completed.stdout)
        self.assert_activation_help(completed.stdout)


if __name__ == '__main__':
    unittest.main()
