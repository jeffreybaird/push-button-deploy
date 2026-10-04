"""Codex audit contract: observe shell changes without granting or blocking calls."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

BASE = Path(__file__).resolve().parents[2] / 'scripts' / 'agent-workflow'
POLICY = {'schema_version': 2, 'source_globs': ['src/**'], 'test_globs': ['tests/**']}
spec = importlib.util.spec_from_file_location('codex_audit_installer', BASE / 'installer.py')
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class CodexAuditContract(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.env = dict(os.environ)
        index = int(self.env.get('GIT_CONFIG_COUNT', '0'))
        self.env.update({'GIT_CONFIG_COUNT': str(index + 1),
                         f'GIT_CONFIG_KEY_{index}': 'commit.gpgsign',
                         f'GIT_CONFIG_VALUE_{index}': 'false'})
        self.git('init', '-q')
        for path, contents in {'src/app.py': 'value = 1\n', 'tests/test_app.py': 'assert True\n',
                               'README.md': 'notes\n', 'policy.json': json.dumps(POLICY)}.items():
            destination = self.root / path
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_text(contents)
        self.git('add', '.')
        self.git('-c', 'user.name=Audit Test', '-c', 'user.email=audit@example.invalid', 'commit', '-qm', 'fixture')

    def git(self, *args):
        return subprocess.run(['git', *args], cwd=self.root, env=self.env,
                              capture_output=True, text=True, check=True).stdout.strip()

    def hook(self, name, identity='shell-1', role='workflow_implementer', tool='Bash', response=None,
             omit_post_context=False):
        event = {'hook_event_name': name, 'tool_name': tool, 'tool_use_id': identity,
                 'session_id': 'codex-session', 'agent_id': 'codex-agent',
                 'tool_input': {'command': 'fixture command'}, 'cwd': str(self.root)}
        if role is not None:
            event['agent_type'] = role
        if response is not None:
            event['tool_response'] = response
        if omit_post_context:
            for key in ('agent_id', 'agent_type', 'tool_input'):
                event.pop(key, None)
        result = subprocess.run([sys.executable, '-B', str(BASE / 'workflow_audit.py'),
                                 '--platform', 'codex', '--root', str(self.root),
                                 '--policy', str(self.root / 'policy.json')],
                                input=json.dumps(event), capture_output=True, text=True,
                                cwd=self.root, env=self.env)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual({}, json.loads(result.stdout))

    def entries(self):
        log = self.root / '.agent-audit/bash.jsonl'
        return [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []

    def entry(self):
        entries = self.entries()
        self.assertEqual(1, len(entries), entries)
        return entries[0]

    def test_source_update_records_codex_identity_and_success(self):
        self.hook('PreToolUse')
        (self.root / 'src/app.py').write_text('value = 2\n')
        self.hook('PostToolUse', response={'exit_code': 0})
        entry = self.entry()
        self.assertEqual(('codex', 'implementer', 'success', 'fixture command'),
                         (entry['platform'], entry['role'], entry['outcome'], entry['command']))
        self.assertEqual([], entry['violations'])
        self.assertIn('-value = 1', entry['changes'][0]['diff'])
        self.assertIn('+value = 2', entry['changes'][0]['diff'])

    def test_underscore_spec_writer_add_delete_and_violation(self):
        self.hook('PreToolUse', role='workflow_spec_writer')
        (self.root / 'tests/new.py').write_text('assert 2 == 2\n')
        (self.root / 'src/app.py').unlink()
        self.hook('PostToolUse', role='workflow_spec_writer', response={'metadata': {'exit_code': 0}})
        entry = self.entry()
        changes = {change['path']: change for change in entry['changes']}
        self.assertEqual('spec_writer', entry['role'])
        self.assertEqual('added', changes['tests/new.py']['change'])
        self.assertTrue(changes['tests/new.py']['owner_ok'])
        self.assertEqual('deleted', changes['src/app.py']['change'])
        self.assertEqual(['src/app.py'], entry['violations'])

    def test_dirty_snapshot_and_noncode_exclusion(self):
        (self.root / 'src/app.py').write_text('value = 10\n')
        (self.root / 'private-notes.txt').write_text('private data before\n')
        self.hook('PreToolUse')
        (self.root / 'src/app.py').write_text('value = 11\n')
        (self.root / 'private-notes.txt').write_text('private data after\n')
        self.hook('PostToolUse', response={'exit_code': 0})
        [change] = self.entry()['changes']
        self.assertEqual('src/app.py', change['path'])
        self.assertIn('-value = 10', change['diff'])
        blob = subprocess.run(['git', 'hash-object', '--stdin'], input='private data before\n',
                              cwd=self.root, capture_output=True, text=True, check=True).stdout.strip()
        self.assertNotEqual(0, subprocess.run(['git', 'cat-file', '-e', blob], cwd=self.root,
                                            capture_output=True).returncode)

    def test_post_outcome_uses_exit_status_or_remains_unknown(self):
        responses = [({'exit_code': 1}, 'failure'), ({'metadata': {'exit_code': 2}}, 'failure'),
                     (json.dumps({'exit_code': 0}), 'success'),
                     (json.dumps({'metadata': {'exit_code': 3}}), 'failure'),
                     ({}, 'unknown'), ('unstructured output', 'unknown'),
                     ({'exit_code': 'not a status'}, 'unknown'), ({'exit_code': False}, 'unknown'),
                     ({'exit_code': True}, 'unknown'), ({'exit_code': 0.5}, 'unknown')]
        for index, (response, expected) in enumerate(responses):
            with self.subTest(response=response):
                self.hook('PreToolUse', identity=f'outcome-{index}')
                (self.root / 'src/app.py').write_text(f'value = {index + 20}\n')
                self.hook('PostToolUse', identity=f'outcome-{index}', response=response)
                self.assertEqual(expected, self.entries()[-1]['outcome'])

    def test_main_with_agent_id_and_malformed_role_have_no_ownership(self):
        for index, (role, expected) in enumerate([(None, 'main'), ('unrecognized-role', None)]):
            self.hook('PreToolUse', identity=f'role-{index}', role=role)
            (self.root / 'src/app.py').write_text(f'value = {index + 30}\n')
            self.hook('PostToolUse', identity=f'role-{index}', role=role, response={'exit_code': 0})
            entry = self.entries()[-1]
            self.assertEqual(expected, entry['role'])
            self.assertEqual(['src/app.py'], entry['violations'])

    def test_patch_completion_before_delayed_shell_post_marks_ambiguity(self):
        self.hook('PreToolUse', identity='long-shell', role='workflow_runner')
        self.hook('PreToolUse', identity='patch', tool='apply_patch')
        (self.root / 'src/app.py').write_text('value = 40\n')
        self.hook('PostToolUse', identity='patch', tool='apply_patch')
        self.assertEqual([], self.entries())
        self.hook('PostToolUse', identity='long-shell', role='workflow_runner', response={'exit_code': 0},
                  omit_post_context=True)
        entry = self.entry()
        self.assertEqual(['patch'], entry['overlapping_tool_use_ids'])
        self.assertEqual('ambiguous', entry['attribution'])
        self.assertEqual(('runner', 'codex-agent', 'workflow_runner', 'fixture command'),
                         (entry['role'], entry['agent_id'], entry['agent_type'], entry['command']))

    def test_patch_still_running_at_shell_completion_marks_ambiguity(self):
        self.hook('PreToolUse', identity='shell')
        self.hook('PreToolUse', identity='patch', tool='apply_patch')
        (self.root / 'src/app.py').write_text('value = 41\n')
        self.hook('PostToolUse', identity='shell', response={'exit_code': 0})
        self.assertEqual(['patch'], self.entry()['overlapping_tool_use_ids'])
        self.assertEqual('ambiguous', self.entry()['attribution'])

    def test_patch_alone_and_noncode_shell_changes_do_not_log(self):
        self.hook('PreToolUse', identity='patch', tool='apply_patch')
        (self.root / 'src/app.py').write_text('value = 50\n')
        self.hook('PostToolUse', identity='patch', tool='apply_patch')
        self.hook('PreToolUse')
        (self.root / 'README.md').write_text('new notes\n')
        self.hook('PostToolUse', response={'exit_code': 0})
        self.assertEqual([], self.entries())


class CodexAuditInstallation(unittest.TestCase):
    def test_installs_synchronous_hooks_preserves_custom_hooks_and_is_idempotent(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            custom = {'matcher': 'Bash', 'hooks': [{'type': 'command', 'command': 'echo custom-audit'}]}
            path_as_data = {'matcher': 'Bash', 'hooks': [{'type': 'command', 'command':
                            'echo ' + str(root / '.codex/hooks/workflow_audit.py')}]}
            (root / '.codex').mkdir()
            (root / '.codex/hooks.json').write_text(json.dumps({'hooks': {
                'PreToolUse': [custom, path_as_data], 'PostToolUse': [custom], 'SessionStart': [custom]}}))
            installer.install(root, POLICY)
            config = json.loads((root / '.codex/hooks.json').read_text())['hooks']
            self.assertNotIn('PostToolUseFailure', config)
            self.assertIn(path_as_data, config['PreToolUse'])
            for event in ('PreToolUse', 'PostToolUse'):
                self.assertIn(custom, config[event])
                audits = [(registration, hook) for registration in config[event]
                          for hook in registration['hooks'] if 'workflow_audit.py' in hook['command']
                          and not hook['command'].startswith('echo ')]
                self.assertEqual(1, len(audits))
                registration, hook = audits[0]
                self.assertEqual('^(Bash|apply_patch)$', registration['matcher'])
                self.assertIn('--platform codex', hook['command'])
                self.assertFalse(hook.get('async', False))
            self.assertEqual([custom], config['SessionStart'])
            self.assertEqual((BASE / 'workflow_audit.py').read_bytes(),
                             (root / '.codex/hooks/workflow_audit.py').read_bytes())
            claude = json.loads((root / '.claude/settings.json').read_text())['hooks']
            for event in ('PreToolUse', 'PostToolUse', 'PostToolUseFailure'):
                self.assertTrue(any('workflow_audit.py' in hook['command']
                                    for registration in claude[event] for hook in registration['hooks']))
            first = {str(path.relative_to(root)): path.read_bytes() for path in root.rglob('*') if path.is_file()}
            installer.install(root, POLICY)
            self.assertEqual(first, {str(path.relative_to(root)): path.read_bytes()
                                     for path in root.rglob('*') if path.is_file()})


if __name__ == '__main__':
    unittest.main()
