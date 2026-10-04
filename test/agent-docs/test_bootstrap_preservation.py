"""Bootstrap must not silently update an already-managed app's agent docs."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class BootstrapPreservation(unittest.TestCase):
    def test_repeat_prepare_and_check_preserve_existing_managed_drift(self):
        with tempfile.TemporaryDirectory() as temporary:
            work = Path(temporary).resolve()
            app = work / 'existing_tool'
            app.mkdir()
            environment = {**os.environ, 'PYTHONDONTWRITEBYTECODE': '1'}
            result = subprocess.run(['bash', str(ROOT / 'agent-docs.sh'), 'update', str(app),
                                     '--framework', 'bash-cli'], env=environment,
                                    cwd=work, capture_output=True, text=True)
            self.assertEqual(0, result.returncode, result.stdout + result.stderr)
            drift = app / '.docs/agent-workflow.md'
            drift.write_text(drift.read_text() + '\nLocal managed edit; explicit reconciliation required.\n')
            (app / '.docs/project-guidance.md').write_text('App-specific deployment constraint.\n')
            owned_roots = ['AGENTS.md', 'CLAUDE.md', '.docs', '.codex', '.claude', 'doc', '.agent-docs-manifest.json']

            def snapshot():
                paths = []
                for name in owned_roots:
                    path = app / name
                    paths.extend(path.rglob('*') if path.is_dir() else [path])
                return {str(path.relative_to(app)): (path.read_bytes(), path.stat().st_mtime_ns)
                        for path in paths if path.is_file()}

            before = snapshot()
            script = r'''
set -euo pipefail
SCRIPT_DIR="$1"
log() { :; }
warn() { :; }
fail() { printf '%s\n' "$*" >&2; exit 1; }
. "$SCRIPT_DIR/scripts/app-types.sh"
. "$SCRIPT_DIR/scripts/provider.sh"
. "$SCRIPT_DIR/scripts/bootstrap/app.sh"
is_phoenix() { [ "$FRAMEWORK" = phoenix ]; }
is_static() { [ "$FRAMEWORK" = zola ]; }
prepare_app "$2" cli bash-cli none github
'''
            result = subprocess.run(['bash', '-c', script, '_', str(ROOT), str(app)], env=environment,
                                    cwd=work, capture_output=True, text=True)
            self.assertEqual(0, result.returncode, result.stdout + result.stderr)
            self.assertEqual(before, snapshot())

            # A real public --check uses an isolated bundle and local auth double.
            # No real credentials, .env, application generation or cloud commands.
            tool = work / 'tool'
            tool.mkdir()
            shutil.copy2(ROOT / 'bootstrap.sh', tool / 'bootstrap.sh')
            shutil.copytree(ROOT / 'scripts', tool / 'scripts', ignore=shutil.ignore_patterns('__pycache__'))
            binary = work / 'bin'
            binary.mkdir()
            gh = binary / 'gh'
            gh.write_text('#!/usr/bin/env bash\n[ "$*" = "auth status" ]\n')
            gh.chmod(0o755)
            result = subprocess.run(['bash', str(tool / 'bootstrap.sh'), '--check', '--cli', 'bash', str(app)],
                                    env={'HOME': os.environ['HOME'], 'PATH': str(binary) + ':' + os.environ['PATH'],
                                         'PYTHONDONTWRITEBYTECODE': '1', 'TF_PLUGIN_CACHE_DIR': str(work / 'cache')},
                                    cwd=work, capture_output=True, text=True)
            self.assertEqual(0, result.returncode, result.stdout + result.stderr)
            self.assertEqual(before, snapshot())


if __name__ == '__main__':
    unittest.main()
