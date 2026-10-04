"""The new scope removes only restrictions attributable to this installer."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

BASE = Path(__file__).resolve().parents[2] / 'scripts' / 'agent-workflow'
spec = importlib.util.spec_from_file_location('scope_installer', BASE / 'installer.py')
installer = importlib.util.module_from_spec(spec); spec.loader.exec_module(installer)
INJECTED = ['Edit(/' + p + ')' for p in ['.claude/**', '.codex/**', '**/.claude/**', '**/.codex/**', '.git/**', '**/.git/**', 'AGENTS.md', 'CLAUDE.md', '**/AGENTS.md', '**/CLAUDE.md', '.docs/agent-workflow.md', '**/.docs/agent-workflow.md']]
POLICY = {'schema_version': 2, 'source_globs': ['src/**/*.py', 'src/*.py'], 'test_globs': ['tests/**']}

class ScopeMigration(unittest.TestCase):
    def test_fresh_install_does_not_add_permissions_sandbox_or_agent_tool_limits(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            installer.install(root, POLICY)
            settings = json.loads((root / '.claude/settings.json').read_text())
            self.assertNotIn('permissions', settings)
            self.assertNotIn('sandbox', settings)
            for path in (root / '.claude/agents').glob('*.md'):
                text = path.read_text()
                self.assertNotIn('\ntools:', text)
                self.assertNotIn('\ndisallowedTools:', text)
                self.assertNotIn('\npermissionMode:', text)

    def test_migration_removes_only_proven_injected_restrictions(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            (root / '.claude').mkdir(); (root / '.codex/hooks').mkdir(parents=True)
            baseline = {'permissions': {'deny': [INJECTED[0], 'Bash(rm:*)']}, 'sandbox': {'enabled': False, 'allowUnsandboxedCommands': True, 'custom': 'keep'}}
            current = {'permissions': {'deny': [*INJECTED, 'Bash(rm:*)', 'Edit(/user-added/**)'], 'allow': ['Read']}, 'sandbox': {'enabled': True, 'allowUnsandboxedCommands': False, 'custom': 'keep'}}
            (root / '.claude/settings.json').write_text(json.dumps(current))
            (root / '.codex/hooks/workflow-manifest.json').write_text(json.dumps({'version': '1.0.0', 'sha256': {}}))
            installer.install(root, POLICY, previous_claude_settings=baseline)
            settings = json.loads((root / '.claude/settings.json').read_text())
            self.assertEqual([INJECTED[0], 'Bash(rm:*)', 'Edit(/user-added/**)'], settings['permissions']['deny'])
            self.assertEqual(['Read'], settings['permissions']['allow'])
            self.assertEqual(baseline['sandbox'], settings['sandbox'])

    def test_unknown_provenance_and_postinstall_user_changes_are_preserved(self):
        for provide_baseline in (False, True):
            with tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve()
                (root / '.claude').mkdir(); (root / '.codex/hooks').mkdir(parents=True)
                current = {'permissions': {'deny': [INJECTED[0], 'Edit(/user-owned/**)']}, 'sandbox': {'enabled': False, 'allowUnsandboxedCommands': True}}
                (root / '.claude/settings.json').write_text(json.dumps(current))
                (root / '.codex/hooks/workflow-manifest.json').write_text(json.dumps({'version': '1.0.0', 'sha256': {}}))
                kwargs = {'previous_claude_settings': {}} if provide_baseline else {}
                installer.install(root, POLICY, **kwargs)
                settings = json.loads((root / '.claude/settings.json').read_text())
                self.assertEqual(current['sandbox'], settings['sandbox'])
                expected = ['Edit(/user-owned/**)'] if provide_baseline else current['permissions']['deny']
                self.assertEqual(expected, settings['permissions']['deny'])
