"""Regression for the exact tool name observed in native Codex hook events.

This is an explicit spelling adapter, not permission to strip arbitrary tool
namespaces. Existing role and malformed-identity restrictions still apply.
"""
import importlib.util
from pathlib import Path
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1] / 'workflow_guard.py'
spec = importlib.util.spec_from_file_location('workflow_guard_native_coordination', SOURCE)
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


class NativeCoordinationContract(unittest.TestCase):
    def test_observed_collaborationspawn_agent_keeps_role_boundary(self):
        policy = {'schema_version': 1, 'test_globs': ['tests/**'],
                  'artifact_roots': ['.agent-artifacts'], 'test_commands': []}
        with tempfile.TemporaryDirectory() as temporary:
            root = str(Path(temporary).resolve())
            for role in (None, 'orchestrator', 'spec_writer', 'implementer', 'runner', 'reviewer'):
                event = {'hook_event_name': 'PreToolUse', 'cwd': root,
                         'tool_name': 'collaborationspawn_agent',
                         'tool_input': {'agent_type': 'workflow_reviewer', 'prompt': 'Review assigned work'}}
                if role is not None:
                    event.update(agent_id='native-child', agent_type='workflow_' + role)
                with self.subTest(role=role):
                    result = guard.evaluate_event('codex', event, root, policy)
                    self.assertEqual('allow' if role in (None, 'orchestrator') else 'deny',
                                     result['hookSpecificOutput']['permissionDecision'])

    def test_current_host_coordination_tools_use_an_explicit_finite_adapter(self):
        policy = {'schema_version': 1, 'test_globs': ['tests/**'],
                  'artifact_roots': ['.agent-artifacts'], 'test_commands': []}
        operations = ('spawn_agent', 'send_message', 'followup_task',
                      'list_agents', 'wait_agent', 'interrupt_agent')
        with tempfile.TemporaryDirectory() as temporary:
            root = str(Path(temporary).resolve())
            for operation in operations:
                for tool in ('collaboration' + operation, 'collaboration.' + operation):
                    for role in (None, 'orchestrator', 'spec_writer', 'implementer', 'runner', 'reviewer'):
                        event = {'hook_event_name': 'PreToolUse', 'cwd': root,
                                 'tool_name': tool, 'tool_input': {}}
                        if role is not None:
                            event.update(agent_id='child', agent_type='workflow_' + role)
                        with self.subTest(tool=tool, role=role):
                            result = guard.evaluate_event('codex', event, root, policy)
                            self.assertEqual('allow' if role in (None, 'orchestrator') else 'deny',
                                             result['hookSpecificOutput']['permissionDecision'])

    def test_exact_native_alias_does_not_grant_unknown_names_or_malformed_identity(self):
        policy = {'schema_version': 1, 'test_globs': ['tests/**'],
                  'artifact_roots': ['.agent-artifacts'], 'test_commands': []}
        with tempfile.TemporaryDirectory() as temporary:
            root = str(Path(temporary).resolve())
            cases = [
                ('collaborationspawn_agent', {'agent_id': 'child'}),
                ('collaborationspawn_agent', {'agent_type': 'workflow_orchestrator'}),
                ('collaborationspawn_agent', {'agent_id': 'child', 'agent_type': 'unknown'}),
                ('collaborationspawn_agent', {'agent_id': '', 'agent_type': ''}),
                ('mcp__arbitrary__spawn_agent', {}),
                ('arbitraryspawn_agent', {}),
                ('collaborationarbitrary_write', {}),
                ('collaboration.arbitrary_write', {}),
            ]
            for tool, identity in cases:
                event = {'hook_event_name': 'PreToolUse', 'cwd': root, 'tool_name': tool,
                         'tool_input': {'agent_type': 'workflow_orchestrator', 'prompt': 'Delegate'}}
                event.update(identity)
                with self.subTest(tool=tool, identity=identity):
                    result = guard.evaluate_event('codex', event, root, policy)
                    self.assertEqual('deny', result['hookSpecificOutput']['permissionDecision'])


if __name__ == '__main__':
    unittest.main()
