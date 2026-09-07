#!/usr/bin/env python3
"""Offline PTY and bootstrap dispatch tests (Python stdlib only)."""
import os
from pathlib import Path
import pty
import re
import select
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
INSTALL = ROOT / 'scripts/install-agent-files.sh'
ENV = {k: v for k, v in os.environ.items() if k not in ('APP_AGENTS', 'APP_EXTRA_DEPS')}


def terminal_case(folder, answers, expected):
    folder.mkdir()
    (folder / 'config.toml').write_text('title = "Example"\n')
    master, slave = pty.openpty()
    process = subprocess.Popen([str(INSTALL), str(folder)], stdin=slave,
                               stderr=slave, stdout=subprocess.PIPE, env=ENV)
    os.close(slave)
    transcript = b''
    try:
        for answer in answers:
            deadline = time.monotonic() + 15
            while b'[1]: ' not in transcript:
                assert time.monotonic() < deadline, 'prompt timed out'
                if select.select([master], [], [], 0.2)[0]:
                    transcript += os.read(master, 4096)
            transcript = b''
            os.write(master, answer)
        output, _ = process.communicate(timeout=30)
        if expected is None:
            assert process.returncode != 0
            assert not (folder / 'CLAUDE.md').exists()
            assert not (folder / 'AGENTS.md').exists()
        else:
            assert process.returncode == 0, output.decode()
            assert (folder / 'CLAUDE.md').exists() == (expected != 'codex')
            assert (folder / 'AGENTS.md').exists() == (expected != 'claude')
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        os.close(master)


with tempfile.TemporaryDirectory(prefix='agent-flow.', dir=str(Path(tempfile.gettempdir()).resolve())) as tmp:
    tmp = Path(tmp)
    terminal_case(tmp / 'enter', [b'\n'], 'claude')
    terminal_case(tmp / 'codex', [b'2\n'], 'codex')
    terminal_case(tmp / 'both', [b'3\n'], 'both')
    terminal_case(tmp / 'retry', [b'wrong\n', b'codex\n'], 'codex')
    terminal_case(tmp / 'cancel', [b'\x04'], None)

    # Load only the actual functions under test, excluding bootstrap's logging,
    # credentials loading, traps, and provisioning entrypoint.
    bootstrap = (ROOT / 'bootstrap.sh').read_text()
    functions = []
    for name in ('ensure_app', 'main', 'abs_dir'):
        match = re.search(r'^' + name + r'\(\) \{\n.*?^\}', bootstrap, re.M | re.S)
        assert match, name
        functions.append(match.group())
    harness = tmp / 'bootstrap-functions.sh'
    harness.write_text('''set -euo pipefail
fail() { echo "$*" >&2; exit 1; }
log() { :; }
is_sinatra() { [ "$FRAMEWORK" = sinatra ]; }
is_zola() { [ "$FRAMEWORK" = zola ]; }
is_sqlite() { return 0; }
set_infra_dirs() { :; }
preflight() { printf 'checked\\n'; }
provision() { ensure_app; }
HOST_APP_DIR=""
''' + '\n'.join(functions) + '\nmain "$@"\n')
    bin_dir = tmp / 'bin'
    bin_dir.mkdir()
    mix = bin_dir / 'mix'
    mix.write_text('''#!/usr/bin/env bash
set -eu
[ "$1" = phx.new ]
mkdir -p "$2"
cat > "$2/mix.exs" <<'MIX'
defmodule FreshApp.MixProject do
  def project, do: [app: :fresh_app]
  defp deps do
    [
      {:phoenix, "~> 1.8"},
    ]
  end
end
MIX
''')
    mix.chmod(0o755)
    for framework in ('phoenix', 'sinatra', 'zola'):
        env = dict(ENV, SCRIPT_DIR=str(ROOT), FRAMEWORK=framework,
                   APP_AGENTS='codex', PATH=str(bin_dir) + os.pathsep + ENV['PATH'])
        app = tmp / ('bootstrap_' + framework)
        subprocess.run(['bash', str(harness), str(app)], env=env, check=True,
                       stdin=subprocess.DEVNULL, stdout=subprocess.PIPE)
        assert (app / 'AGENTS.md').exists()
        assert not (app / 'CLAUDE.md').exists()
        if framework == 'phoenix':
            assert '{:req,' in (app / 'mix.exs').read_text()
        (app / 'AGENTS.md').write_text('custom instructions\n')
        env['APP_AGENTS'] = 'both'
        subprocess.run(['bash', str(harness), str(app)], env=env, check=True,
                       stdin=subprocess.DEVNULL, stdout=subprocess.PIPE)
        assert (app / 'AGENTS.md').read_text() == 'custom instructions\n'
        assert not (app / 'CLAUDE.md').exists()
        target = tmp / ('check_' + framework)
        output = subprocess.check_output(['bash', str(harness), '--check', str(target)], env=env)
        assert output == b'checked\n'
        assert not target.exists()
    # Shell-only configuration is exported by bootstrap before generators run.
    block = bootstrap.split('# Validate agent configuration', 1)[1].split('FRAMEWORK=', 1)[0]
    subprocess.run(['bash', '-c', 'set -eu\nfail() { exit 1; }\nAPP_AGENTS=both\n# Validate agent configuration' + block +
                    '\nbash -c \'test "$APP_AGENTS" = both\''], env=ENV, check=True)
print('PASS: terminal choices and stubbed bootstrap integration')
