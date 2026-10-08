"""Privacy and process contract for the generated Codex diagnostic wrapper."""
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import signal
import stat
import subprocess
import sys
import tempfile
import time
import unittest

import test_codex_audit as audit_contract

BASE = Path(__file__).resolve().parents[2] / 'scripts/agent-workflow'
WRAPPER = BASE / 'hook_diagnostics.py'
FIELDS = {'hook', 'event', 'timestamp', 'duration_ms', 'exit_code', 'signal', 'error_category'}
AUDIT_ERRORS = ('ValueError', 'TypeError', 'KeyError', 'RuntimeError', 'OSError',
                'FileNotFoundError', 'PermissionError', 'UnicodeDecodeError', 'JSONDecodeError')


class DiagnosticsHelpers:
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()

    def command(self, child, hook='workflow_guard', event='PreToolUse', root=None):
        return [sys.executable, '-B', str(WRAPPER), '--hook', hook, '--event', event,
                '--root', str(root or self.root), '--', *child]

    def run_child(self, code, payload=b'', **kwargs):
        return subprocess.run(self.command([sys.executable, '-B', '-c', code], **kwargs),
                              input=payload, capture_output=True, timeout=10)

    def records(self):
        path = self.root / '.agent-diagnostics/hooks.jsonl'
        self.assertTrue(path.is_file(), 'a completed wrapper must record diagnostics')
        return [json.loads(line) for line in path.read_bytes().splitlines()]

    def record(self, code=0, category=None, signum=None, hook='workflow_guard', event='PreToolUse'):
        entry = self.records()[-1]
        self.assertEqual(FIELDS, set(entry))
        self.assertEqual((hook, event, code, signum, category),
                         tuple(entry[key] for key in ('hook', 'event', 'exit_code', 'signal', 'error_category')))
        timestamp = datetime.fromisoformat(entry['timestamp'])
        self.assertEqual(timezone.utc.utcoffset(timestamp), timestamp.utcoffset())
        self.assertLess(abs((datetime.now(timezone.utc) - timestamp).total_seconds()), 30)
        self.assertIsInstance(entry['duration_ms'], (int, float))
        self.assertGreaterEqual(entry['duration_ms'], 0)
        return entry


class DiagnosticsContract(DiagnosticsHelpers, unittest.TestCase):
    def test_binary_stdin_stdout_stderr_and_nonzero_exit_are_unchanged(self):
        payload = b'PAYLOAD_SECRET\x00\xff\n' * 10000
        code = ('import sys; data=sys.stdin.buffer.read(); '
                'sys.stdout.buffer.write(data); sys.stderr.buffer.write(data[::-1]); sys.exit(23)')
        result = self.run_child(code, payload)
        self.assertEqual((23, payload, payload[::-1]),
                         (result.returncode, result.stdout, result.stderr))
        self.record(23, 'nonzero_exit')
        raw = (self.root / '.agent-diagnostics/hooks.jsonl').read_bytes()
        self.assertNotIn(b'PAYLOAD_SECRET', raw)
        self.assertNotIn(code.encode(), raw)
        self.assertNotIn(str(self.root).encode(), raw)

    def test_success_schema_and_measured_duration(self):
        self.assertEqual(0, self.run_child('import time; time.sleep(.05)').returncode)
        self.assertGreaterEqual(self.record()['duration_ms'], 40)

    def test_only_allowlisted_error_categories_are_persisted(self):
        for name in (*AUDIT_ERRORS, 'SecretException'):
            with self.subTest(name=name):
                message = f'workflow audit skipped: {name}\n'
                result = self.run_child(f'import sys; sys.stderr.write({message!r})',
                                        hook='workflow_audit', event='PostToolUse')
                self.assertEqual((0, message.encode()), (result.returncode, result.stderr))
                self.record(category='audit_skipped_' + (name if name in AUDIT_ERRORS else 'unknown'),
                            hook='workflow_audit', event='PostToolUse')
        result = self.run_child('raise RuntimeError("EXCEPTION_MESSAGE_SECRET")')
        self.assertEqual(1, result.returncode)
        self.assertIn(b'EXCEPTION_MESSAGE_SECRET', result.stderr)
        self.record(1, 'unhandled_exception')
        raw = (self.root / '.agent-diagnostics/hooks.jsonl').read_text()
        for secret in ('SecretException', 'EXCEPTION_MESSAGE_SECRET', 'Traceback', 'sys.stderr'):
            self.assertNotIn(secret, raw)

    def test_fragmented_audit_marker_is_recognized_without_retaining_stderr(self):
        code = ('import os,time; os.write(2,b"private "*2000+b"workflow audit ski"); '
                'time.sleep(.03); os.write(2,b"pped: ValueError\\n")')
        result = self.run_child(code, hook='workflow_audit')
        self.assertEqual(0, result.returncode)
        self.assertIn(b'workflow audit skipped: ValueError\n', result.stderr)
        self.record(category='audit_skipped_ValueError', hook='workflow_audit')
        self.assertNotIn('private', (self.root / '.agent-diagnostics/hooks.jsonl').read_text())

    def test_child_startup_failure_has_safe_category(self):
        result = subprocess.run(self.command([str(self.root / 'MISSING_SECRET_COMMAND')]),
                                capture_output=True, timeout=5)
        self.assertEqual(127, result.returncode)
        self.record(127, 'startup_failure')
        self.assertNotIn('MISSING_SECRET_COMMAND',
                         (self.root / '.agent-diagnostics/hooks.jsonl').read_text())

    def test_hook_and_event_identity_are_allowlisted(self):
        for flag in ('--hook', '--event'):
            command = self.command([sys.executable, '-c', 'print("must not execute")'])
            command[command.index(flag) + 1] = 'IDENTITY_SECRET'
            result = subprocess.run(command, capture_output=True, timeout=5)
            self.assertNotEqual(0, result.returncode)
            self.assertEqual(b'', result.stdout)
            self.assertFalse((self.root / '.agent-diagnostics').exists())

    def test_child_self_signals_preserve_process_status(self):
        for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP, signal.SIGQUIT, signal.SIGKILL):
            with self.subTest(signum=signum):
                result = self.run_child('import os,signal; signal.signal(signal.SIGINT,signal.SIG_DFL); '
                                        f'os.kill(os.getpid(),{int(signum)})')
                self.assertEqual(-signum, result.returncode)
                self.record(None, 'signal', signum)

    def test_wrapper_forwards_term_and_int_and_retains_status(self):
        for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP, signal.SIGQUIT):
            with self.subTest(signum=signum):
                code = ('import signal,time; signal.signal(signal.SIGINT,signal.SIG_DFL); '
                        'print("ready",flush=True); time.sleep(10)')
                process = subprocess.Popen(self.command([sys.executable, '-B', '-c', code]),
                                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                try:
                    self.assertEqual(b'ready\n', process.stdout.readline())
                    process.send_signal(signum)
                    stdout, stderr = process.communicate(timeout=5)
                    self.assertEqual((-signum, b'', b''), (process.returncode, stdout, stderr))
                    self.record(None, 'signal', signum)
                finally:
                    if process.poll() is None:
                        process.kill()
                    process.communicate()

    def test_owner_only_permissions_correct_existing_permissive_modes(self):
        directory = self.root / '.agent-diagnostics'
        directory.mkdir(mode=0o777)
        path = directory / 'hooks.jsonl'
        path.write_text('')
        directory.chmod(0o777)
        path.chmod(0o666)
        self.assertEqual(0, self.run_child('pass').returncode)
        self.record()
        self.assertEqual(0o700, stat.S_IMODE(directory.stat().st_mode))
        self.assertEqual(0o600, stat.S_IMODE(path.stat().st_mode))
        self.assertEqual(os.geteuid(), path.stat().st_uid)

    def test_foreign_owner_directory_and_file_are_refused_before_mutation(self):
        spec = importlib.util.spec_from_file_location('diagnostics_owner_contract', WRAPPER)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        from unittest.mock import patch
        original_fstat = os.fstat
        for target in ('directory', 'file'):
            with self.subTest(target=target):
                def foreign_owner(descriptor):
                    info = original_fstat(descriptor)
                    matched = stat.S_ISDIR(info.st_mode) if target == 'directory' else stat.S_ISREG(info.st_mode)
                    if matched:
                        values = list(info)
                        values[4] = os.geteuid() + 1
                        return os.stat_result(values)
                    return info

                with patch.object(module.os, 'fstat', side_effect=foreign_owner), \
                        patch.object(module.os, 'fchmod') as chmod, \
                        patch.object(module.os, 'write') as write:
                    module.write_record(str(self.root), {'hook': 'workflow_guard'})
                    chmod.assert_not_called()
                    write.assert_not_called()

    def test_child_catching_forwarded_signal_preserves_final_decision_and_exit(self):
        code = ('import os,signal,time; '
                'signal.signal(signal.SIGTERM,lambda *_: '
                '(os.write(1,b"final decision\\n"),os.write(2,b"final stderr\\n"),os._exit(23))); '
                'print("ready",flush=True); time.sleep(10)')
        process = subprocess.Popen(self.command([sys.executable, '-B', '-c', code]),
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            self.assertEqual(b'ready\n', process.stdout.readline())
            process.send_signal(signal.SIGTERM)
            stdout, stderr = process.communicate(timeout=5)
            self.assertEqual((23, b'final decision\n', b'final stderr\n'),
                             (process.returncode, stdout, stderr))
            self.record(23, 'nonzero_exit')
        finally:
            if process.poll() is None:
                process.kill()
            process.communicate()

    def test_rotation_bounds_complete_json_records(self):
        directory = self.root / '.agent-diagnostics'
        directory.mkdir()
        path = directory / 'hooks.jsonl'
        valid = dict(hook='workflow_guard', event='PreToolUse', timestamp='2020-01-01T00:00:00+00:00',
                     duration_ms=1, exit_code=0, signal=None, error_category=None)
        path.write_text((json.dumps(valid) + '\n') * 1000)
        self.assertEqual(0, self.run_child('pass').returncode)
        self.assertLessEqual(path.stat().st_size, 65536)
        self.assertGreater(len(self.records()), 1)
        for record in self.records():
            self.assertEqual(FIELDS, set(record))
        self.record()

    def test_concurrent_writers_produce_valid_bounded_records(self):
        with ThreadPoolExecutor(max_workers=12) as pool:
            results = list(pool.map(lambda _: self.run_child('print("ok")'), range(60)))
        for result in results:
            self.assertEqual((0, b'ok\n', b''), (result.returncode, result.stdout, result.stderr))
        records = self.records()
        self.assertGreater(len(records), 0)
        self.assertLessEqual(len(records), 60)  # Busy-lock records may be dropped.
        self.assertLessEqual((self.root / '.agent-diagnostics/hooks.jsonl').stat().st_size, 65536)
        for record in records:
            self.assertEqual(FIELDS, set(record))

    def test_unsafe_destinations_and_busy_lock_cannot_change_hook_output(self):
        outside = self.root / 'outside'
        outside.mkdir()
        sentinel = outside / 'sentinel'
        sentinel.write_bytes(b'PRIVATE_DESTINATION')
        directory = self.root / '.agent-diagnostics'
        for kind in ('directory_symlink', 'log_symlink', 'hardlink', 'fifo', 'directory_file', 'log_directory'):
            with self.subTest(kind=kind):
                if kind == 'directory_symlink':
                    directory.symlink_to(outside, target_is_directory=True)
                elif kind == 'directory_file':
                    directory.write_bytes(b'PRIVATE_DESTINATION')
                else:
                    directory.mkdir()
                    log = directory / 'hooks.jsonl'
                    if kind == 'log_symlink':
                        log.symlink_to(sentinel)
                    elif kind == 'hardlink':
                        log.hardlink_to(sentinel)
                    elif kind == 'fifo':
                        os.mkfifo(log)
                    else:
                        log.mkdir()
                result = self.run_child('import sys; print("decision"); sys.stderr.write("error"); sys.exit(17)')
                self.assertEqual((17, b'decision\n', b'error'),
                                 (result.returncode, result.stdout, result.stderr))
                self.assertEqual(b'PRIVATE_DESTINATION', sentinel.read_bytes())
                if directory.is_symlink() or directory.is_file():
                    directory.unlink()
                else:
                    log = directory / 'hooks.jsonl'
                    if log.is_dir():
                        log.rmdir()
                    else:
                        log.unlink()
                    directory.rmdir()
        directory.mkdir()
        log = directory / 'hooks.jsonl'
        log.write_text('')
        with log.open('r+') as locked:
            fcntl.flock(locked, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = self.run_child('print("decision")')
            self.assertEqual((0, b'decision\n', b''), (result.returncode, result.stdout, result.stderr))
            self.assertEqual('', log.read_text())
        result = self.run_child('print("decision")', root=self.root / 'missing-root')
        self.assertEqual((0, b'decision\n', b''), (result.returncode, result.stdout, result.stderr))

    def test_injected_write_failure_does_not_escape(self):
        spec = importlib.util.spec_from_file_location('diagnostics_failure_contract', WRAPPER)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        from unittest.mock import patch
        with patch.object(module.os, 'write', side_effect=OSError('WRITE_SECRET')):
            module.write_record(str(self.root), {'hook': 'workflow_guard'})
        path = self.root / '.agent-diagnostics/hooks.jsonl'
        self.assertNotIn(b'WRITE_SECRET', path.read_bytes())

    def test_unexpected_logging_exception_preserves_completed_child_outcome(self):
        import contextlib
        import io
        from unittest.mock import patch
        spec = importlib.util.spec_from_file_location('diagnostics_main_failure_contract', WRAPPER)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        stdout, stderr = io.StringIO(), io.StringIO()

        def completed_child(_command):
            print('final decision')
            print('final stderr', file=sys.stderr)
            return 23, 'nonzero_exit'

        argv = ['hook_diagnostics.py', '--hook', 'workflow_guard', '--event', 'PreToolUse',
                '--root', str(self.root), '--', 'fixture-child']
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr), \
                patch.object(module.sys, 'argv', argv), \
                patch.object(module, 'execute', side_effect=completed_child), \
                patch.object(module, 'write_record', side_effect=RuntimeError('LOGGING_EXCEPTION_SECRET')):
            result = module.main()
        self.assertEqual((23, 'final decision\n', 'final stderr\n'),
                         (result, stdout.getvalue(), stderr.getvalue()))
        self.assertFalse((self.root / '.agent-diagnostics').exists())


class RealHookParity(DiagnosticsHelpers, unittest.TestCase):
    def setUp(self):
        self.fixture = audit_contract.CodexAuditContract()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.root = self.fixture.root

    def real_command(self, name):
        return [sys.executable, '-B', str(BASE / (name + '.py')), '--platform', 'codex',
                '--root', str(self.root), '--policy', str(self.root / 'policy.json')]

    def real_run(self, name, event, wrapped):
        child = self.real_command(name)
        command = self.command(child, hook=name, event=event['hook_event_name']) if wrapped else child
        return subprocess.run(command, input=json.dumps(event).encode(), capture_output=True,
                              cwd=self.root, env=self.fixture.env, timeout=10)

    def test_guard_actual_allow_deny_and_malformed_input_parity(self):
        for role in ('workflow_implementer', 'workflow_reviewer'):
            event = {'hook_event_name': 'PreToolUse', 'tool_name': 'apply_patch',
                     'agent_id': 'private-agent', 'agent_type': role,
                     'tool_input': {'command': '*** Begin Patch\n*** Add File: src/a.py\n+SECRET\n*** End Patch'}}
            direct = self.real_run('workflow_guard', event, False)
            wrapped = self.real_run('workflow_guard', event, True)
            self.assertEqual((direct.returncode, direct.stdout, direct.stderr),
                             (wrapped.returncode, wrapped.stdout, wrapped.stderr))
            decision = json.loads(wrapped.stdout)
            if role == 'workflow_implementer':
                self.assertEqual({}, decision)
            else:
                self.assertEqual('deny', decision['hookSpecificOutput']['permissionDecision'])
        for payload in (b'{invalid SECRET', b'null'):
            direct = subprocess.run(self.real_command('workflow_guard'), input=payload, capture_output=True)
            wrapped = subprocess.run(self.command(self.real_command('workflow_guard')), input=payload,
                                     capture_output=True)
            self.assertEqual((direct.returncode, direct.stdout, direct.stderr),
                             (wrapped.returncode, wrapped.stdout, wrapped.stderr))
        self.assertNotIn('SECRET', (self.root / '.agent-diagnostics/hooks.jsonl').read_text())

    def test_real_audit_caught_skip_parity_and_category(self):
        # Malformed policy exercises the real audit's caught-error path.
        (self.root / 'policy.json').write_text('{INVALID_POLICY_SECRET')
        event = {'hook_event_name': 'PreToolUse', 'tool_name': 'Bash', 'tool_use_id': 'private',
                 'tool_input': {'command': 'SECRET_COMMAND'}, 'agent_id': 'SECRET_ID',
                 'agent_type': 'workflow_implementer'}
        direct = self.real_run('workflow_audit', event, False)
        wrapped = self.real_run('workflow_audit', event, True)
        self.assertEqual((0, b'{}\n', direct.stderr),
                         (wrapped.returncode, wrapped.stdout, wrapped.stderr))
        self.assertIn(b'workflow audit skipped:', direct.stderr)
        category = direct.stderr.decode().strip().rsplit(' ', 1)[-1]
        self.record(category='audit_skipped_' + (category if category in AUDIT_ERRORS else 'unknown'),
                    hook='workflow_audit')
        self.assertNotIn('SECRET', (self.root / '.agent-diagnostics/hooks.jsonl').read_text())

    def test_real_audit_pre_post_success_and_failure_preserve_entries(self):
        for wrapped in (False, True):
            for status in (0, 9):
                identity = f'parity-{wrapped}-{status}'
                event = {'hook_event_name': 'PreToolUse', 'tool_name': 'Bash', 'tool_use_id': identity,
                         'tool_input': {'command': 'fixture command'}, 'agent_id': 'private-agent',
                         'agent_type': 'workflow_implementer'}
                result = self.real_run('workflow_audit', event, wrapped)
                self.assertEqual((0, b'{}\n', b''), (result.returncode, result.stdout, result.stderr))
                (self.root / 'src/app.py').write_text(f'value = {identity!r}\n')
                event.update(hook_event_name='PostToolUse', tool_response={'exit_code': status})
                result = self.real_run('workflow_audit', event, wrapped)
                self.assertEqual((0, b'{}\n', b''), (result.returncode, result.stdout, result.stderr))
                entry = self.fixture.entries()[-1]
                self.assertEqual('success' if status == 0 else 'failure', entry['outcome'])
                self.assertEqual([], entry['violations'])
                self.assertEqual('fixture command', entry['command'])
        for entry in self.records():
            self.assertEqual(FIELDS, set(entry))
            self.assertEqual('workflow_audit', entry['hook'])
            self.assertIsNone(entry['error_category'])
        raw = (self.root / '.agent-diagnostics/hooks.jsonl').read_text()
        self.assertNotIn('private-agent', raw)
        self.assertNotIn('fixture command', raw)


if __name__ == '__main__':
    unittest.main()
