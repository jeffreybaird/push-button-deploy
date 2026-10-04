"""Finite Claude native coordination needed to continue an existing child."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1] / 'workflow_guard.py'
spec = importlib.util.spec_from_file_location('workflow_guard_claude_resume', SOURCE)
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


class ClaudeResumeContract(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = str(Path(self.temporary.name).resolve())
        self.policy = {'schema_version': 1, 'test_globs': ['tests/**'],
                       'artifact_roots': ['.agent-artifacts'], 'test_commands': []}

    def decision(self, role, tool, payload):
        event = {'hook_event_name': 'PreToolUse', 'cwd': self.root,
                 'tool_name': tool, 'tool_input': payload}
        if role is not None:
            event.update(agent_id='child', agent_type='workflow_' + role)
        return guard.evaluate_event('claude', event, self.root, self.policy)['hookSpecificOutput']['permissionDecision']

    def test_only_parent_and_orchestrator_discover_and_message_existing_child(self):
        calls = [('ToolSearch', {'query': 'select:SendMessage', 'max_results': 1}),
                 ('ToolSearch', {'query': 'select:SendMessage'}),
                 ('SendMessage', {'to': 'existing-child', 'message': 'Continue assigned review'})]
        for role in (None, 'orchestrator', 'spec_writer', 'implementer', 'runner', 'reviewer'):
            for tool, payload in calls:
                with self.subTest(role=role, tool=tool, payload=payload):
                    self.assertEqual('allow' if role in (None, 'orchestrator') else 'deny',
                                     self.decision(role, tool, payload))

    def test_discovery_is_exact_and_does_not_expose_arbitrary_tool_search(self):
        payloads = [{}, {'query': ''}, {'query': 'SendMessage'},
                    {'query': 'select:Write'}, {'query': 'select:SendMessage,Write'},
                    {'query': 'select:SendMessage ', 'max_results': 1},
                    {'query': 'select:SendMessage', 'max_results': 2},
                    {'query': 'select:SendMessage', 'max_results': 0},
                    {'query': 'select:SendMessage', 'max_results': '1'},
                    {'query': 'select:SendMessage', 'max_results': True},
                    {'query': 'select:SendMessage', 'extra_tool': 'Write'}]
        for role in (None, 'orchestrator'):
            for payload in payloads:
                with self.subTest(role=role, payload=payload):
                    self.assertEqual('deny', self.decision(role, 'ToolSearch', payload))


if __name__ == '__main__':
    unittest.main()
