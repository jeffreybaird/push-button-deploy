"""Pending command context must not extend retention after audit completion."""
import json
from pathlib import Path
import subprocess
import sys
import unittest

import test_codex_audit as audit_contract


class AuditMarkerPrivacy(unittest.TestCase):
    def setUp(self):
        self.fixture = audit_contract.CodexAuditContract()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.root = self.fixture.root

    def hook(self, platform, event):
        command = [sys.executable, '-B', str(audit_contract.BASE / 'workflow_audit.py'),
                   '--root', str(self.root), '--policy', str(self.root / 'policy.json')]
        if platform == 'codex':
            command.extend(['--platform', 'codex'])
        result = subprocess.run(command, input=json.dumps(event), capture_output=True, text=True,
                                cwd=self.root, env=self.fixture.env)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual({}, json.loads(result.stdout))

    def event(self, phase):
        return {'hook_event_name': phase, 'tool_name': 'Bash', 'tool_use_id': 'private-call',
                'session_id': 'private-session', 'agent_id': 'private-agent',
                'agent_type': 'workflow_implementer',
                'tool_input': {'command': 'echo sensitive-value > notes.txt',
                               'private_env': {'API_TOKEN': 'unneeded-secret'}},
                'tool_response': {'exit_code': 0}}

    def marker(self, done=False):
        folder = Path(self.fixture.git('rev-parse', '--absolute-git-dir')) / 'agent-audit'
        return folder / ('done/private-call.json' if done else 'private-call.json')

    def test_default_claude_pending_marker_has_no_command_or_identity(self):
        self.hook('claude', self.event('PreToolUse'))
        raw = self.marker().read_text()
        marker = json.loads(raw)
        self.assertEqual({'tool_use_id', 'tool', 'started', 'head', 'files'}, set(marker))
        for private in ('sensitive-value', 'private-agent', 'private-session', 'workflow_implementer'):
            self.assertNotIn(private, raw)

    def test_completed_codex_marker_keeps_only_timing_after_omitted_post_context(self):
        self.hook('codex', self.event('PreToolUse'))
        pending = self.marker().read_text()
        self.assertIn('sensitive-value', pending)
        self.assertIn('private-agent', pending)
        (self.root / 'notes.txt').write_text('sensitive-value\n')
        post = self.event('PostToolUse')
        for key in ('agent_id', 'agent_type', 'tool_input', 'session_id'):
            del post[key]
        self.hook('codex', post)
        self.assertFalse(self.marker().exists())
        marker = json.loads(self.marker(done=True).read_text())
        self.assertEqual({'tool_use_id', 'tool', 'started', 'ended'}, set(marker))
        self.assertEqual('Bash', marker['tool'])
        self.assertGreaterEqual(marker['ended'], marker['started'])
        self.assertEqual([], self.fixture.entries())

    def test_pending_codex_context_omits_noncommand_arguments(self):
        self.hook('codex', self.event('PreToolUse'))
        raw = self.marker().read_text()
        context = json.loads(raw)['context']
        self.assertEqual({'command': 'echo sensitive-value > notes.txt'}, context['tool_input'])
        self.assertEqual({'agent_id', 'agent_type', 'session_id', 'tool_input'}, set(context))
        self.assertNotIn('unneeded-secret', raw)
        self.assertNotIn('private_env', raw)

    def test_model_context_is_removed_after_noncode_completion(self):
        pre = self.event('PreToolUse')
        pre['model'] = 'runtime-private-model'
        self.hook('codex', pre)
        context = json.loads(self.marker().read_text())['context']
        self.assertEqual('runtime-private-model', context['model'])
        self.assertEqual({'agent_id', 'agent_type', 'session_id', 'tool_input', 'model'}, set(context))
        (self.root / 'notes.txt').write_text('sensitive-value\n')
        post = self.event('PostToolUse')
        for key in ('agent_id', 'agent_type', 'tool_input', 'session_id'):
            del post[key]
        self.hook('codex', post)
        self.assertFalse(self.marker().exists())
        completed = self.marker(done=True).read_text()
        self.assertEqual({'tool_use_id', 'tool', 'started', 'ended'}, set(json.loads(completed)))
        self.assertNotIn('runtime-private-model', completed)
        self.assertEqual([], self.fixture.entries())

    def test_claude_pending_model_does_not_add_context(self):
        pre = self.event('PreToolUse')
        pre['model'] = 'runtime-private-model'
        self.hook('claude', pre)
        pending = self.marker().read_text()
        self.assertEqual({'tool_use_id', 'tool', 'started', 'head', 'files'}, set(json.loads(pending)))
        self.assertNotIn('runtime-private-model', pending)


if __name__ == '__main__':
    unittest.main()
