"""Invalid native TOML structure rejects cleanly before lifecycle writes."""
import os
from pathlib import Path
import json
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class InvalidNativeConfig(unittest.TestCase):
    def test_scalar_features_or_agents_tables_return_structured_error_without_writes(self):
        with tempfile.TemporaryDirectory() as temporary:
            work = Path(temporary).resolve()
            for index, content in enumerate(('features = "invalid"\n', 'agents = "invalid"\n')):
                with self.subTest(content=content):
                    app = work / ('app' + str(index))
                    (app / '.codex').mkdir(parents=True)
                    (app / '.codex/config.toml').write_text(content)
                    (app / 'README.md').write_text('Application-owned data.\n')

                    def snapshot():
                        return {str(path.relative_to(app)): (path.read_bytes(), path.stat().st_mtime_ns)
                                for path in app.rglob('*') if path.is_file()}

                    before = snapshot()
                    for operation in ('check', 'update'):
                        with self.subTest(operation=operation):
                            result = subprocess.run(['bash', str(ROOT / 'agent-docs.sh'), operation, str(app),
                                                     '--framework', 'phoenix', '--json'],
                                                    env={**os.environ, 'PYTHONDONTWRITEBYTECODE': '1'},
                                                    cwd=work, capture_output=True, text=True)
                            self.assertEqual(2, result.returncode, result.stdout + result.stderr)
                            self.assertEqual('error', json.loads(result.stdout)['status'])
                            self.assertNotIn('Traceback', result.stdout + result.stderr)
                            self.assertEqual(before, snapshot())


if __name__ == '__main__':
    unittest.main()
