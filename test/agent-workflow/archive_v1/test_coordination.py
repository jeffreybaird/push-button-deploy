"""Native coordination is usable without granting writer children control."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1] / 'workflow_guard.py'
spec = importlib.util.spec_from_file_location('workflow_guard_coordination', SOURCE)
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


class CoordinationContract(unittest.TestCase):
    def test_native_parent_coordination_and_child_restrictions(self):
        policy = {'schema_version': 1, 'test_globs': ['tests/**'],
                  'artifact_roots': ['.agent-artifacts'], 'test_commands': []}
        with tempfile.TemporaryDirectory() as root:
            for platform, tools in (
                ('codex', ('send_input', 'wait', 'close_agent', 'resume_agent', 'update_plan')),
                ('claude', ('AskUserQuestion', 'TodoWrite', 'TaskOutput'))):
                for role in (None, 'orchestrator', 'spec_writer', 'implementer', 'runner', 'reviewer'):
                    for tool in tools:
                        with self.subTest(platform=platform, role=role, tool=tool):
                            event = {'hook_event_name': 'PreToolUse', 'tool_name': tool,
                                     'tool_input': {}, 'cwd': str(Path(root).resolve())}
                            if role is not None:
                                event.update(agent_id='child', agent_type='workflow_' + role)
                            result = guard.evaluate_event(platform, event, str(Path(root).resolve()), policy)
                            self.assertEqual('allow' if role in (None, 'orchestrator') else 'deny',
                                             result['hookSpecificOutput']['permissionDecision'])

    def test_claude_recognized_child_handback(self):
        policy = {'schema_version': 1, 'test_globs': ['tests/**'],
                  'artifact_roots': ['.agent-artifacts'], 'test_commands': []}
        with tempfile.TemporaryDirectory() as root:
            for role in ('spec_writer', 'implementer', 'runner', 'reviewer', 'orchestrator', 'unknown'):
                event = {'hook_event_name': 'PreToolUse', 'tool_name': 'SubagentHandback',
                         'tool_input': {'summary': 'Finished assigned work'},
                         'agent_id': 'child', 'agent_type': 'workflow_' + role}
                result = guard.evaluate_event('claude', event, str(Path(root).resolve()), policy)
                self.assertEqual('deny' if role == 'unknown' else 'allow',
                                 result['hookSpecificOutput']['permissionDecision'])


if __name__ == '__main__':
    unittest.main()
