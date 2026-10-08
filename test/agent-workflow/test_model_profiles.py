"""Project-owned model profiles overlay native configs without changing gates."""
import importlib.util
import json
from pathlib import Path
import re
import tempfile
import tomllib
import unittest

from test_maintenance import MaintenanceFixture

BASE = Path(__file__).resolve().parents[2] / 'scripts' / 'agent-workflow'
spec = importlib.util.spec_from_file_location('profile_installer', BASE / 'installer.py')
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)
PROFILE_PATH = '.docs/agent-models.json'
PROFILE = {
    'schema_version': 1,
    'codex': {'model': 'gpt-6.1-sol', 'roles': {
        'reviewer': {'model': 'gpt-6-astra'},
        'runner': {'model': 'gpt-6-luna', 'model_reasoning_effort': 'low'}}},
    'claude': {'model': 'claude-opus-5-5', 'roles': {
        'reviewer': {'model': 'claude-fable-5-1'},
        'runner': {'model': 'claude-sonnet-5-5', 'effort': 'low'}}},
}


def write_profile(root, profile):
    path = root / PROFILE_PATH
    path.parent.mkdir(exist_ok=True)
    path.write_text(json.dumps(profile, indent=2) + '\n')


def assert_profile(test, root, profile):
    codex = tomllib.loads((root / '.codex/config.toml').read_text())
    claude = json.loads((root / '.claude/settings.json').read_text())
    for platform, main in (('codex', codex), ('claude', claude)):
        test.assertEqual(profile[platform]['model'], main['model'])
        for role, fields in profile[platform].get('roles', {}).items():
            if platform == 'codex':
                actual = tomllib.loads((root / f'.codex/agents/workflow_{role}.toml').read_text())
                for key, value in fields.items():
                    test.assertEqual(value, actual[key])
            else:
                header = (root / f'.claude/agents/workflow-{role.replace("_", "-")}.md').read_text().split('\n---', 1)[0]
                # Native frontmatter scalar values may use either quoting style.
                actual = dict(line.split(': ', 1) for line in header.splitlines()[1:] if ': ' in line)
                for key, value in fields.items():
                    test.assertEqual(value, actual[key].strip('\"\''))


class ModelProfiles(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.policy = {'schema_version': 2, 'source_globs': ['src/**'], 'test_globs': ['test/**']}

    def snapshot(self):
        return {str(path.relative_to(self.root)): (path.read_bytes(), path.stat().st_mtime_ns)
                for path in self.root.rglob('*') if path.is_file() and not path.is_symlink()}

    def native_settings(self):
        (self.root / '.codex').mkdir(exist_ok=True)
        (self.root / '.claude').mkdir(exist_ok=True)
        (self.root / '.codex/config.toml').write_text(
            '# Keep top comment\nmodel = "user-model" # Keep model comment\n'
            'model_reasoning_effort = "high"\n\n[custom]\n# Keep section comment\nkeep = true\n')
        (self.root / '.claude/settings.json').write_text(json.dumps(
            {'model': 'user-claude', 'env': {'LOCAL': 'keep'}, 'effortLevel': 'high'}))

    def test_guidance_explains_optional_project_profile_and_main_model_removal(self):
        guide = installer.render(self.root, self.policy)['files']['.docs/agent-workflow.md']
        normalized = re.sub(r'\s+', ' ', guide).lower()
        for phrase in ('.docs/agent-models.json', 'schema_version', 'model_reasoning_effort'):
            self.assertIn(phrase, normalized)
        self.assertRegex(normalized, r'optional.{0,100}(?:profile|agent-models)')
        self.assertRegex(normalized, r'(?:remove|removing|omit|omitting).{0,100}main model.{0,160}(?:preserv|keep|retain)')

    def test_no_profile_keeps_main_models_role_inheritance_and_idempotence(self):
        self.native_settings()
        installer.install(self.root, self.policy)
        self.assertEqual('user-model', tomllib.loads((self.root / '.codex/config.toml').read_text())['model'])
        self.assertEqual('user-claude', json.loads((self.root / '.claude/settings.json').read_text())['model'])
        for role in installer.guard.ROLES:
            codex = tomllib.loads((self.root / f'.codex/agents/workflow_{role}.toml').read_text())
            self.assertNotIn('model', codex)
            self.assertNotIn('model_reasoning_effort', codex)
            header = (self.root / f'.claude/agents/workflow-{role.replace("_", "-")}.md').read_text().split('\n---', 1)[0]
            self.assertNotIn('\nmodel:', header)
            self.assertNotIn('\neffort:', header)
        first = {name: data[0] for name, data in self.snapshot().items()}
        installer.install(self.root, self.policy)
        self.assertEqual(first, {name: data[0] for name, data in self.snapshot().items()})

    def test_profile_overlays_only_selected_fields_preserving_native_comments_and_profile(self):
        self.native_settings()
        baseline = installer.render(self.root, self.policy)['files']
        write_profile(self.root, PROFILE)
        profile_before = self.snapshot()[PROFILE_PATH]
        installer.install(self.root, self.policy)
        assert_profile(self, self.root, PROFILE)
        text = (self.root / '.codex/config.toml').read_text()
        for preserved in ('# Keep top comment', '# Keep model comment', '[custom]\n# Keep section comment\nkeep = true'):
            self.assertIn(preserved, text)
        self.assertEqual('high', tomllib.loads(text)['model_reasoning_effort'])
        settings = json.loads((self.root / '.claude/settings.json').read_text())
        self.assertEqual({'LOCAL': 'keep'}, settings['env'])
        self.assertEqual('high', settings['effortLevel'])
        self.assertEqual(profile_before, self.snapshot()[PROFILE_PATH])
        for name, contents in baseline.items():
            if name.startswith(('.codex/hooks/', '.claude/hooks/')) and name != installer.MANIFEST_PATH:
                self.assertEqual(contents, (self.root / name).read_text(), name)
        self.assertEqual(baseline['.codex/hooks.json'], (self.root / '.codex/hooks.json').read_text())
        for role in installer.guard.ROLES:
            name = f'.codex/agents/workflow_{role}.toml'
            self.assertEqual(tomllib.loads(baseline[name])['developer_instructions'],
                             tomllib.loads((self.root / name).read_text())['developer_instructions'])
            name = f'.claude/agents/workflow-{role.replace("_", "-")}.md'
            self.assertEqual(baseline[name].split('\n---\n', 1)[1],
                             (self.root / name).read_text().split('\n---\n', 1)[1])
        manifest = json.loads((self.root / installer.MANIFEST_PATH).read_text())
        self.assertNotIn(PROFILE_PATH, manifest['sha256'])
        self.assertNotIn(PROFILE_PATH, installer.render(self.root, self.policy)['files'])
        first = {name: data[0] for name, data in self.snapshot().items()}
        installer.install(self.root, self.policy)
        self.assertEqual(first, {name: data[0] for name, data in self.snapshot().items()})

    def test_role_removal_clears_model_and_effort_but_main_removal_keeps_native_model(self):
        write_profile(self.root, PROFILE)
        installer.install(self.root, self.policy)
        write_profile(self.root, {'schema_version': 1, 'codex': {}, 'claude': {}})
        installer.install(self.root, self.policy)
        self.assertEqual('gpt-6.1-sol', tomllib.loads((self.root / '.codex/config.toml').read_text())['model'])
        self.assertEqual('claude-opus-5-5', json.loads((self.root / '.claude/settings.json').read_text())['model'])
        runner = tomllib.loads((self.root / '.codex/agents/workflow_runner.toml').read_text())
        self.assertNotIn('model', runner)
        self.assertNotIn('model_reasoning_effort', runner)
        for role in ('runner', 'reviewer'):
            header = (self.root / f'.claude/agents/workflow-{role}.md').read_text().split('\n---', 1)[0]
            self.assertNotIn('\nmodel:', header)
            self.assertNotIn('\neffort:', header)
        (self.root / PROFILE_PATH).unlink()
        installer.install(self.root, self.policy)
        self.assertEqual('gpt-6.1-sol', tomllib.loads((self.root / '.codex/config.toml').read_text())['model'])

    def test_role_only_profile_does_not_select_main_model(self):
        self.native_settings()
        write_profile(self.root, {'schema_version': 1, 'codex': {'roles': {'runner': {'model': 'custom-model'}}}})
        installer.install(self.root, self.policy)
        self.assertEqual('user-model', tomllib.loads((self.root / '.codex/config.toml').read_text())['model'])
        self.assertEqual('user-claude', json.loads((self.root / '.claude/settings.json').read_text())['model'])
        runner = tomllib.loads((self.root / '.codex/agents/workflow_runner.toml').read_text())
        self.assertEqual('custom-model', runner['model'])

    def test_invalid_schema_values_keys_roles_and_efforts_reject_before_writes(self):
        invalid = [[], {}, {'schema_version': True}, {'schema_version': 2},
                   {'schema_version': 1, 'other': {}}, {'schema_version': 1, 'codex': []}]
        for platform, effort in (('codex', 'model_reasoning_effort'), ('claude', 'effort')):
            for value in ('', '   ', 42, None):
                invalid.append({'schema_version': 1, platform: {'model': value}})
                invalid.append({'schema_version': 1, platform: {'roles': {'runner': {'model': value}}}})
            invalid.extend([
                {'schema_version': 1, platform: {'unexpected': True}},
                {'schema_version': 1, platform: {'roles': []}},
                {'schema_version': 1, platform: {'roles': {'unknown': {'model': 'x'}}}},
                {'schema_version': 1, platform: {'roles': {'runner': []}}},
                {'schema_version': 1, platform: {'roles': {'runner': {'unexpected': True}}}},
                {'schema_version': 1, platform: {'roles': {'runner': {effort: 'highest'}}}},
                {'schema_version': 1, platform: {'roles': {'runner': {effort: 1}}}},
                {'schema_version': 1, platform: {'roles': {'runner': {
                    ('effort' if platform == 'codex' else 'model_reasoning_effort'): 'low'}}}},
            ])
        self.native_settings()
        for profile in invalid:
            with self.subTest(profile=profile):
                write_profile(self.root, profile)
                before = self.snapshot()
                with self.assertRaises(ValueError):
                    installer.install(self.root, self.policy)
                self.assertEqual(before, self.snapshot())

    def test_malformed_json_or_symlink_profile_rejects_before_writes(self):
        write_profile(self.root, PROFILE)
        path = self.root / PROFILE_PATH
        path.write_text('{invalid json')
        before = self.snapshot()
        with self.assertRaises(ValueError):
            installer.install(self.root, self.policy)
        self.assertEqual(before, self.snapshot())
        path.unlink()
        outside = self.root / 'outside.json'
        outside.write_text(json.dumps(PROFILE))
        path.symlink_to(outside)
        before = self.snapshot()
        with self.assertRaises((ValueError, OSError)):
            installer.install(self.root, self.policy)
        self.assertEqual(before, self.snapshot())
        self.assertTrue(path.is_symlink())

    def test_native_effort_values_and_each_role_are_supported_without_model_catalogue(self):
        for platform, field, values in (
            ('codex', 'model_reasoning_effort', ('none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max', 'ultra')),
            ('claude', 'effort', ('low', 'medium', 'high', 'xhigh', 'max')),
        ):
            for value in values:
                with self.subTest(platform=platform, effort=value):
                    profile = {'schema_version': 1, platform: {'model': 'project-custom-model', 'roles': {
                        role: {'model': 'project-custom-role-model', field: value} for role in installer.guard.ROLES}}}
                    write_profile(self.root, profile)
                    installer.install(self.root, self.policy)
                    # The assertion helper checks only the explicitly supplied platform.
                    for role in installer.guard.ROLES:
                        if platform == 'codex':
                            fields = tomllib.loads((self.root / f'.codex/agents/workflow_{role}.toml').read_text())
                            self.assertEqual(value, fields[field])
                            self.assertEqual('project-custom-role-model', fields['model'])
                        else:
                            header = (self.root / f'.claude/agents/workflow-{role.replace("_", "-")}.md').read_text().split('\n---', 1)[0]
                            fields = dict(line.split(': ', 1) for line in header.splitlines()[1:] if ': ' in line)
                            self.assertEqual(value, fields[field].strip('\"\''))
                            self.assertEqual('project-custom-role-model', fields['model'].strip('\"\''))

    def test_directory_profile_and_symlink_parent_are_unsafe(self):
        path = self.root / PROFILE_PATH
        path.parent.mkdir()
        path.mkdir()
        before = self.snapshot()
        with self.assertRaises((ValueError, OSError)):
            installer.install(self.root, self.policy)
        self.assertEqual(before, self.snapshot())
        path.rmdir()
        path.parent.rmdir()
        alternate = self.root / 'alternate-docs'
        alternate.mkdir()
        (alternate / 'agent-models.json').write_text(json.dumps(PROFILE))
        path.parent.symlink_to(alternate, target_is_directory=True)
        before = self.snapshot()
        with self.assertRaises((ValueError, OSError)):
            installer.install(self.root, self.policy)
        self.assertEqual(before, self.snapshot())


class ModelProfileMaintenance(MaintenanceFixture):
    def test_profile_change_is_readonly_preview_then_apply_and_removal(self):
        root = self.installed()
        write_profile(root, PROFILE)
        before = self.snapshot(root)
        self.assertEqual('update', self.result(self.cli('check'), 1)['heybridge']['status'])
        diff = self.cli('diff', json_output=False)
        self.assertEqual(1, diff.returncode, diff.stderr)
        self.assertIn('gpt-6-astra', diff.stdout)
        self.assertEqual(before, self.snapshot(root))
        self.result(self.cli('apply'), 0)
        assert_profile(self, root, PROFILE)
        self.assertEqual(before[PROFILE_PATH], self.snapshot(root)[PROFILE_PATH])
        self.commit(root)
        self.assertEqual('current', self.result(self.cli('check'), 0)['heybridge']['status'])
        first = {name: data[0] for name, data in self.snapshot(root).items()}
        self.result(self.cli('apply'), 0)
        self.assertEqual(first, {name: data[0] for name, data in self.snapshot(root).items()})
        write_profile(root, {'schema_version': 1})
        self.result(self.cli('apply'), 0)
        runner = tomllib.loads((root / '.codex/agents/workflow_runner.toml').read_text())
        self.assertNotIn('model', runner)
        self.assertNotIn('model_reasoning_effort', runner)


if __name__ == '__main__':
    unittest.main()
