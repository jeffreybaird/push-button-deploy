"""Repository-specific protected paths take precedence over every role grant."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1] / 'workflow_guard.py'
spec = importlib.util.spec_from_file_location('workflow_guard_protections', SOURCE)
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


class RepositoryProtections(unittest.TestCase):
    def test_protected_globs_override_test_artifact_and_source_authority(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            for directory in ('data', 'src', '.agent-artifacts'):
                (root / directory).mkdir()
            policy = {'schema_version': 1, 'test_globs': ['data/**'],
                      'artifact_roots': ['.agent-artifacts'], 'test_commands': [],
                      'protected_globs': ['data/**', 'src/clinical_constants.py',
                                          '.agent-artifacts/reference/**']}
            for role in ('spec_writer', 'implementer', 'runner', 'reviewer', 'orchestrator'):
                for path in ('data/measurements.csv', 'src/clinical_constants.py',
                             '.agent-artifacts/reference/measurements.csv'):
                    for platform in ('codex', 'claude'):
                        with self.subTest(role=role, path=path, platform=platform):
                            event = {'hook_event_name': 'PreToolUse', 'cwd': str(root),
                                     'agent_id': 'child', 'agent_type': 'workflow_' + role}
                            if platform == 'codex':
                                event.update(tool_name='apply_patch', tool_input={'command':
                                    f'*** Begin Patch\n*** Add File: {path}\n+change\n*** End Patch'})
                            else:
                                event.update(tool_name='Write', tool_input={'file_path': path,
                                                                            'content': 'change'})
                            result = guard.evaluate_event(platform, event, str(root), policy)
                            self.assertEqual('deny', result['hookSpecificOutput']['permissionDecision'])
            event = {'hook_event_name': 'PreToolUse', 'cwd': str(root),
                     'agent_id': 'child', 'agent_type': 'workflow_implementer',
                     'tool_name': 'Write', 'tool_input': {'file_path': 'src/app.py', 'content': 'change'}}
            self.assertEqual('allow', guard.evaluate_event('claude', event, str(root), policy)
                             ['hookSpecificOutput']['permissionDecision'])

    def test_malformed_protected_globs_denied(self):
        with tempfile.TemporaryDirectory() as temporary:
            for invalid in ('data/**', [7], ['../outside/**']):
                policy = {'schema_version': 1, 'test_globs': ['tests/**'],
                          'artifact_roots': ['.agent-artifacts'], 'test_commands': [],
                          'protected_globs': invalid}
                event = {'hook_event_name': 'PreToolUse', 'agent_id': 'child',
                         'agent_type': 'workflow_implementer', 'tool_name': 'Write',
                         'tool_input': {'file_path': 'app.py', 'content': 'change'}}
                result = guard.evaluate_event('claude', event, str(Path(temporary).resolve()), policy)
                self.assertEqual('deny', result['hookSpecificOutput']['permissionDecision'])


if __name__ == '__main__':
    unittest.main()
