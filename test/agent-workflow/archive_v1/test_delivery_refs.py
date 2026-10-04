"""Fully qualified refs must not bypass bounded branch-name delivery checks."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1] / 'workflow_guard.py'
spec = importlib.util.spec_from_file_location('workflow_guard_delivery_refs', SOURCE)
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


class DeliveryRefs(unittest.TestCase):
    def test_qualified_refs_denied_for_parent_and_orchestrator(self):
        policy = {'schema_version': 1, 'test_globs': ['tests/**'],
                  'artifact_roots': ['.agent-artifacts'], 'test_commands': [],
                  'delivery_enabled': True, 'delivery_commands': []}
        with tempfile.TemporaryDirectory() as temporary:
            root = str(Path(temporary).resolve())
            for platform in ('codex', 'claude'):
                for role in (None, 'orchestrator'):
                    for ref in ('refs/heads/main', 'refs/heads/master', 'refs/heads/workflow/task'):
                        for prefix in ('git push -u origin ', 'git switch -c '):
                            with self.subTest(platform=platform, role=role, command=prefix + ref):
                                event = {'hook_event_name': 'PreToolUse', 'cwd': root,
                                         'tool_name': 'Bash' if platform == 'claude' else 'exec_command',
                                         'tool_input': {'command': prefix + ref}}
                                if role is not None:
                                    event.update(agent_id='child', agent_type='workflow_' + role)
                                result = guard.evaluate_event(platform, event, root, policy)
                                self.assertEqual('deny', result['hookSpecificOutput']['permissionDecision'])


if __name__ == '__main__':
    unittest.main()
