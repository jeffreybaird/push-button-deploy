"""Unsupported Python must fail bootstrap preflight before provisioning."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class PythonPreflight(unittest.TestCase):
    def test_check_rejects_python_older_than_311_before_app_or_cloud_changes(self):
        with tempfile.TemporaryDirectory() as temporary:
            work = Path(temporary).resolve()
            tool = work / 'tool'
            tool.mkdir()
            shutil.copy2(ROOT / 'bootstrap.sh', tool / 'bootstrap.sh')
            shutil.copytree(ROOT / 'scripts', tool / 'scripts', ignore=shutil.ignore_patterns('__pycache__'))
            binary = work / 'bin'
            binary.mkdir()
            python = binary / 'python3'
            python.write_text('''#!/usr/bin/env bash
printf '%s\\n' "$*" >> "$PYTHON_PREFLIGHT_CALLS"
case "$*" in
  *--version*|-V) printf 'Python 3.10.14\\n'; exit 0 ;;
  *version_info*) exit 1 ;;
  *) printf 'Unexpected unsupported interpreter invocation\\n' >&2; exit 99 ;;
esac
''')
            python.chmod(0o755)
            for command in ('gh', 'curl', 'terraform', 'doctl', 'ssh', 'scp'):
                mock = binary / command
                mock.write_text('''#!/usr/bin/env bash
if [ "$(basename "$0") $*" = 'gh auth status' ]; then exit 0; fi
printf '%s\\n' "$(basename "$0") $*" >> "$PREFLIGHT_EXTERNAL_CALLS"
exit 99
''')
                mock.chmod(0o755)
            app = work / 'not_created'
            calls = work / 'python-calls'
            external = work / 'external-calls'
            result = subprocess.run(['bash', str(tool / 'bootstrap.sh'), '--check', '--cli', 'bash', str(app)],
                                    env={'HOME': os.environ['HOME'], 'PATH': str(binary) + ':' + os.environ['PATH'],
                                         'TF_PLUGIN_CACHE_DIR': str(work / 'cache'), 'PYTHON_PREFLIGHT_CALLS': str(calls),
                                         'PREFLIGHT_EXTERNAL_CALLS': str(external)},
                                    cwd=work, capture_output=True, text=True)
            self.assertNotEqual(0, result.returncode, result.stdout + result.stderr)
            self.assertIn('3.11', result.stdout + result.stderr)
            self.assertTrue(calls.is_file(), 'Preflight must inspect Python version, not only binary presence')
            self.assertFalse(app.exists())
            self.assertFalse(external.exists(), 'Unsupported Python must never reach provisioning')


if __name__ == '__main__':
    unittest.main()
