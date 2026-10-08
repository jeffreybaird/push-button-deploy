"""Lifecycle previews and updates honor a project-owned model profile."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import tomllib
import unittest

ROOT = Path(__file__).resolve().parents[2]
PROFILE_PATH = '.docs/agent-models.json'


class LifecycleModelProfiles(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        (self.root / '.docs').mkdir()

    def cli(self, operation, expected=0):
        result = subprocess.run(['bash', str(ROOT / 'agent-docs.sh'), operation, str(self.root),
                                 '--framework', 'react', '--json'], capture_output=True, text=True,
                                env={**os.environ, 'PYTHONDONTWRITEBYTECODE': '1'})
        self.assertEqual(expected, result.returncode, result.stdout + result.stderr)
        return result

    def snapshot(self):
        return {str(path.relative_to(self.root)): (path.read_bytes(), path.stat().st_mtime_ns)
                for path in self.root.rglob('*') if path.is_file()}

    def profile(self, codex_model='gpt-6.1-sol'):
        profile = {
            'schema_version': 1,
            'codex': {'model': codex_model, 'roles': {
                'reviewer': {'model': 'gpt-6-astra'},
                'runner': {'model': 'gpt-6-luna', 'model_reasoning_effort': 'low'}}},
            'claude': {'model': 'claude-opus-5-5', 'roles': {
                'reviewer': {'model': 'claude-fable-5-1'},
                'runner': {'model': 'claude-sonnet-5-5', 'effort': 'low'}}},
        }
        (self.root / PROFILE_PATH).write_text(json.dumps(profile, indent=2) + '\n')

    def assert_models(self, codex_model):
        self.assertEqual(codex_model, tomllib.loads((self.root / '.codex/config.toml').read_text())['model'])
        self.assertEqual('claude-opus-5-5', json.loads((self.root / '.claude/settings.json').read_text())['model'])
        runner = tomllib.loads((self.root / '.codex/agents/workflow_runner.toml').read_text())
        reviewer = tomllib.loads((self.root / '.codex/agents/workflow_reviewer.toml').read_text())
        self.assertEqual('gpt-6-luna', runner['model'])
        self.assertEqual('low', runner['model_reasoning_effort'])
        self.assertEqual('gpt-6-astra', reviewer['model'])
        for role, model in (('reviewer', 'claude-fable-5-1'), ('runner', 'claude-sonnet-5-5')):
            header = (self.root / f'.claude/agents/workflow-{role}.md').read_text().split('\n---', 1)[0]
            fields = dict(line.split(': ', 1) for line in header.splitlines()[1:] if ': ' in line)
            self.assertEqual(model, fields['model'].strip('\"\''))
            if role == 'runner':
                self.assertEqual('low', fields['effort'].strip('\"\''))

    def test_fresh_profile_and_changed_profile_propagate_with_readonly_preview(self):
        self.profile()
        profile_before = self.snapshot()[PROFILE_PATH]
        self.cli('update')
        self.assert_models('gpt-6.1-sol')
        self.assertEqual(profile_before, self.snapshot()[PROFILE_PATH])
        manifest = json.loads((self.root / '.agent-docs-manifest.json').read_text())
        self.assertNotIn(PROFILE_PATH, manifest['files'])
        self.profile('project-new-codex')
        before = self.snapshot()
        self.cli('check', 1)
        self.cli('diff', 1)
        self.assertEqual(before, self.snapshot())
        self.cli('update')
        self.assert_models('project-new-codex')
        self.assertEqual(before[PROFILE_PATH], self.snapshot()[PROFILE_PATH])
        updated = self.snapshot()
        self.cli('update')
        self.assertEqual(updated, self.snapshot())
        self.cli('check')

    def test_invalid_profile_blocks_lifecycle_before_any_write(self):
        (self.root / PROFILE_PATH).write_text(json.dumps(
            {'schema_version': 1, 'codex': {'roles': {'runner': {'effort': 'low'}}}}))
        before = self.snapshot()
        self.cli('update', 2)
        self.assertEqual(before, self.snapshot())


if __name__ == '__main__':
    unittest.main()
