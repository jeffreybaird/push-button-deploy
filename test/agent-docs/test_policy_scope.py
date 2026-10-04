"""Generic framework policy must not classify arbitrary JSON data as source."""
import fnmatch
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class PolicyScope(unittest.TestCase):
    def test_typescript_json_data_native_configuration_and_manifests_are_unscoped(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary).resolve() / 'typescript_app'
            app.mkdir()
            result = subprocess.run(['bash', str(ROOT / 'agent-docs.sh'), 'update', str(app),
                                     '--framework', 'ts-cli', '--json'],
                                    env={**os.environ, 'PYTHONDONTWRITEBYTECODE': '1'},
                                    cwd=temporary, capture_output=True, text=True)
            self.assertEqual(0, result.returncode, result.stdout + result.stderr)
            for platform in ('codex', 'claude'):
                policy = json.loads((app / ('.' + platform) / 'hooks/policy.json').read_text())
                for path in ('data/example.json', 'src/data/example.json', '.claude/settings.json',
                             '.codex/hooks.json', '.agent-docs-manifest.json'):
                    with self.subTest(platform=platform, path=path):
                        self.assertFalse(any(fnmatch.fnmatchcase(path, pattern)
                                             for pattern in policy['source_globs'] + policy['test_globs']),
                                         'JSON data/configuration must remain outside source/test ownership: ' + path)
                self.assertTrue(any(fnmatch.fnmatchcase('src/index.ts', pattern)
                                    for pattern in policy['source_globs']))
                self.assertTrue(any(fnmatch.fnmatchcase('test/index.test.ts', pattern)
                                    for pattern in policy['test_globs']))


if __name__ == '__main__':
    unittest.main()
