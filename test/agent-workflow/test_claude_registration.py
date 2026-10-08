"""Guard hook registration must remain portable and preserve ownership."""
import importlib.util
import json
import os
import shlex
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

BASE = Path(__file__).resolve().parents[2] / 'scripts' / 'agent-workflow'
spec = importlib.util.spec_from_file_location('installer_claude_registration', BASE / 'installer.py')
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)
policies_spec = importlib.util.spec_from_file_location('repo_policies_registration', BASE / 'repo_policies.py')
repo_policies = importlib.util.module_from_spec(policies_spec)
policies_spec.loader.exec_module(repo_policies)
POLICY = {'schema_version': 2, 'source_globs': ['src/*.py'], 'test_globs': ['tests/**']}


def managed_claude_hooks(settings):
    return [hook for registration in settings['hooks']['PreToolUse'] for hook in registration['hooks']
            if 'workflow_guard.py' in hook['command']]


def managed_claude_registrations(settings):
    return [registration for registration in settings['hooks']['PreToolUse']
            if any('workflow_guard.py' in hook['command'] for hook in registration['hooks'])]


class ClaudeRegistration(unittest.TestCase):
    def install(self, root):
        installer.install(root, POLICY)
        return json.loads((root / '.claude/settings.json').read_text())

    def test_command_resolves_paths_from_project_dir_not_install_location(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            [hook] = managed_claude_hooks(self.install(root))
            self.assertNotIn(str(root), hook['command'])
            self.assertEqual('python3 -B "$CLAUDE_PROJECT_DIR/.claude/hooks/workflow_guard.py" '
                             '--platform claude --root "$CLAUDE_PROJECT_DIR" '
                             '--policy "$CLAUDE_PROJECT_DIR/.claude/hooks/policy.json"', hook['command'])

    def test_matcher_limited_to_guarded_edit_tools(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            [registration] = managed_claude_registrations(self.install(root))
            self.assertEqual('Write|Edit|NotebookEdit', registration['matcher'])

    def test_reinstall_replaces_previous_absolute_registration(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            (root / '.claude').mkdir()
            absolute = ('python3 -B ' + str(root / '.claude/hooks/workflow_guard.py') + ' --platform claude --root '
                        + str(root) + ' --policy ' + str(root / '.claude/hooks/policy.json'))
            (root / '.claude/settings.json').write_text(json.dumps({'hooks': {'PreToolUse': [
                {'matcher': '.*', 'hooks': [{'type': 'command', 'command': absolute, 'timeout': 5}]}]}}))
            settings = self.install(root)
            self.assertEqual(1, len(managed_claude_registrations(settings)))
            self.assertNotIn(absolute, json.dumps(settings))

    def test_reinstall_is_byte_idempotent(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            self.install(root)
            first = (root / '.claude/settings.json').read_bytes()
            self.install(root)
            self.assertEqual(first, (root / '.claude/settings.json').read_bytes())

    def test_registered_command_denies_forbidden_edit_from_relocated_checkout(self):
        with tempfile.TemporaryDirectory() as temporary:
            original = Path(temporary).resolve() / 'original'
            original.mkdir()
            [hook] = managed_claude_hooks(self.install(original))
            moved = Path(temporary).resolve() / 'moved'
            original.rename(moved)
            event = {'hook_event_name': 'PreToolUse', 'tool_name': 'Edit', 'cwd': str(moved),
                     'tool_input': {'file_path': str(moved / 'src/app.py')}}
            result = subprocess.run(hook['command'], shell=True, input=json.dumps(event), text=True,
                                    capture_output=True, env={**os.environ, 'CLAUDE_PROJECT_DIR': str(moved)})
            self.assertEqual(0, result.returncode, result.stderr)
            self.assertEqual('deny', json.loads(result.stdout)['hookSpecificOutput']['permissionDecision'])

    def test_guide_names_claude_main_session_as_orchestrator(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            installer.install(root, POLICY)
            guide = (root / '.docs/agent-workflow.md').read_text()
            self.assertIn('Claude subagents cannot start other subagents', guide)
            self.assertIn('main session acts as orchestrator', guide)


class CodexRegistration(unittest.TestCase):
    def install(self, root):
        installer.install(root, POLICY)
        return json.loads((root / '.codex/hooks.json').read_text())

    def guard(self, settings):
        def owned_execution(hook):
            argv = shlex.split(hook['command'])
            if (len(argv) > 2 and argv[:2] == ['python3', '-B'] and
                    argv[2].endswith('/.codex/hooks/hook_diagnostics.py')):
                self.assertIn('--', argv)
                self.assertIn('--hook', argv)
                if argv[argv.index('--hook') + 1] != 'workflow_guard':
                    return False
                argv = argv[argv.index('--') + 1:]
            return (len(argv) > 2 and argv[:2] == ['python3', '-B'] and
                    argv[2].endswith('/.codex/hooks/workflow_guard.py'))
        registrations = [r for r in settings['hooks']['PreToolUse']
                         if any(owned_execution(h) for h in r['hooks'])]
        self.assertEqual(1, len(registrations))
        [registration] = registrations
        self.assertEqual('.*', registration['matcher'])
        [hook] = [h for h in registration['hooks'] if owned_execution(h)]
        return hook

    def test_command_resolves_script_root_and_policy_from_git_root(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve() / 'checkout with spaces'
            root.mkdir()
            command = self.guard(self.install(root))['command']
            self.assertNotIn(str(root), command)
            self.assertIn('git rev-parse --show-toplevel', command)
            # Execution below verifies shell quoting and all three resolved paths.

    def test_registered_command_preserves_ownership_after_relocation_from_nested_cwd(self):
        with tempfile.TemporaryDirectory() as temporary:
            original = Path(temporary).resolve() / 'original checkout'
            original.mkdir()
            subprocess.run(['git', 'init', '-q', str(original)], check=True, capture_output=True)
            command = self.guard(self.install(original))['command']
            moved = original.with_name('relocated checkout with spaces')
            original.rename(moved)
            nested = moved / 'nested' / 'working directory'
            nested.mkdir(parents=True)
            for role, path, expected in ((None, 'src/app.py', 'deny'),
                                         ('implementer', 'src/app.py', 'allow'),
                                         ('implementer', 'tests/test_app.py', 'deny'),
                                         ('spec_writer', 'tests/test_app.py', 'allow'),
                                         ('spec_writer', 'src/app.py', 'deny')):
                with self.subTest(role=role, path=path):
                    event = {'hook_event_name': 'PreToolUse', 'tool_name': 'apply_patch',
                             'cwd': str(nested), 'tool_input': {'command':
                                 '*** Begin Patch\n*** Add File: ' + str(moved / path) +
                                 '\n+contract\n*** End Patch'}}
                    if role:
                        event.update(agent_id='native-child', agent_type='workflow_' + role)
                    result = subprocess.run(command, shell=True, input=json.dumps(event), text=True,
                                            cwd=nested, capture_output=True)
                    self.assertEqual(0, result.returncode, result.stderr)
                    output = json.loads(result.stdout)
                    if expected == 'allow':
                        self.assertEqual({}, output)
                    else:
                        self.assertEqual('deny', output['hookSpecificOutput']['permissionDecision'])
            self.assertFalse((moved / 'src/app.py').exists())
            self.assertFalse((moved / 'tests/test_app.py').exists())

    def test_migrates_absolute_registration_preserving_external_hooks(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve() / 'checkout with spaces'
            root.mkdir()
            (root / '.codex').mkdir()
            absolute = ' '.join(shlex.quote(x) for x in [
                'python3', '-B', str(root / '.codex/hooks/workflow_guard.py'),
                '--platform', 'codex', '--root', str(root),
                '--policy', str(root / '.codex/hooks/policy.json')])
            external = {'type': 'command', 'command': 'echo external', 'timeout': 12}
            external_registration = {'matcher': 'Bash', 'hooks': [external], 'custom': 'keep'}
            settings = {'custom': {'keep': True}, 'hooks': {'PreToolUse': [
                {'matcher': '.*', 'hooks': [external, {'type': 'command', 'command': absolute,
                                                     'timeout': 5}]}, external_registration]}}
            (root / '.codex/hooks.json').write_text(json.dumps(settings))
            installed = self.install(root)
            self.assertNotIn(absolute, json.dumps(installed))
            self.guard(installed)
            self.assertEqual({'keep': True}, installed['custom'])
            self.assertIn(external_registration, installed['hooks']['PreToolUse'])
            self.assertIn({'matcher': '.*', 'hooks': [external]}, installed['hooks']['PreToolUse'])

    def test_reinstall_preserves_external_same_basename_and_script_path_as_data(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve() / 'checkout with spaces'
            root.mkdir()
            (root / '.codex').mkdir()
            external = {'matcher': '.*', 'hooks': [{'type': 'command',
                'command': 'python3 -B /opt/team/hooks/workflow_guard.py --platform codex',
                'timeout': 17}], 'custom': 'external guard'}
            data_only = {'matcher': 'Bash', 'hooks': [{'type': 'command',
                'command': "echo '$(git rev-parse --show-toplevel)/.codex/hooks/workflow_guard.py' --platform codex",
                'timeout': 23}], 'custom': 'path as data'}
            (root / '.codex/hooks.json').write_text(json.dumps(
                {'hooks': {'PreToolUse': [external, data_only]}}))
            installed = self.install(root)
            self.guard(installed)
            self.assertIn(external, installed['hooks']['PreToolUse'])
            self.assertIn(data_only, installed['hooks']['PreToolUse'])
            first = (root / '.codex/hooks.json').read_bytes()
            reinstalled = self.install(root)
            self.guard(reinstalled)
            self.assertIn(external, reinstalled['hooks']['PreToolUse'])
            self.assertIn(data_only, reinstalled['hooks']['PreToolUse'])
            self.assertEqual(first, (root / '.codex/hooks.json').read_bytes())

    def test_reinstall_is_byte_idempotent_including_relocated_checkout(self):
        with tempfile.TemporaryDirectory() as temporary:
            original = Path(temporary).resolve() / 'original checkout'
            original.mkdir()
            self.install(original)
            def snapshot(root):
                return {str(path.relative_to(root)): path.read_bytes()
                        for path in root.rglob('*') if path.is_file()}
            first = snapshot(original)
            self.install(original)
            self.assertEqual(first, snapshot(original))
            moved = original.with_name('relocated checkout with spaces')
            original.rename(moved)
            self.install(moved)
            self.guard(json.loads((moved / '.codex/hooks.json').read_text()))
            self.assertEqual(first, snapshot(moved))
            self.install(moved)
            self.assertEqual(first, snapshot(moved))


AUDIT_COMMAND = ('python3 -B "$CLAUDE_PROJECT_DIR/.claude/hooks/workflow_audit.py" --root "$CLAUDE_PROJECT_DIR" '
                 '--policy "$CLAUDE_PROJECT_DIR/.claude/hooks/policy.json"')


class AuditRegistration(unittest.TestCase):
    def audit_registrations(self, settings):
        return {event: [r for r in registrations if 'workflow_audit.py' in json.dumps(r)]
                for event, registrations in settings['hooks'].items()}

    def test_audit_registered_for_bash_and_edit_tools_before_and_after(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            installer.install(root, POLICY)
            found = self.audit_registrations(json.loads((root / '.claude/settings.json').read_text()))
            for event in ('PreToolUse', 'PostToolUse', 'PostToolUseFailure'):
                self.assertEqual([{'matcher': 'Bash|Write|Edit|NotebookEdit', 'hooks': [
                    {'type': 'command', 'command': AUDIT_COMMAND, 'timeout': 10}]}], found[event], event)

    def test_audit_script_copied_and_registration_idempotent(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            installer.install(root, POLICY)
            first = (root / '.claude/settings.json').read_bytes()
            installer.install(root, POLICY)
            self.assertEqual(first, (root / '.claude/settings.json').read_bytes())
            self.assertEqual((BASE / 'workflow_audit.py').read_bytes(),
                             (root / '.claude/hooks/workflow_audit.py').read_bytes())

    def test_gitattributes_union_merge_added_once_preserving_existing(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            (root / '.gitattributes').write_text('*.png binary\n')
            installer.install(root, POLICY)
            installer.install(root, POLICY)
            self.assertEqual('*.png binary\n.agent-audit/*.jsonl merge=union\n',
                             (root / '.gitattributes').read_text())

    def test_guide_describes_audit_log(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            installer.install(root, POLICY)
            guide = (root / '.docs/agent-workflow.md').read_text()
            self.assertIn('.agent-audit/bash.jsonl', guide)
            self.assertIn('The command is recorded verbatim', guide)
            self.assertIn('not proof of who made', guide)
            self.assertNotIn('secrets in unscoped files never enter the log', guide)


class RepositoryPolicyCoverage(unittest.TestCase):
    def classify(self, repo, path):
        policy = repo_policies.REPO_POLICIES[repo]
        root = Path('/repo')
        return installer.guard.classification(root / path, root, policy)

    def test_rode_archive_seed_data_is_unscoped(self):
        self.assertIsNone(self.classify('rode', 'priv/repo/seed_data/crossings.exs'))

    def test_rode_repo_scripts_and_migrations_remain_source(self):
        for path in ('priv/repo/seeds.exs', 'priv/repo/pg_to_sqlite.exs',
                     'priv/repo/migrations/20260101000000_create_sections.exs'):
            self.assertEqual('source', self.classify('rode', path), path)

    def test_rode_seed_release_script_is_source(self):
        self.assertEqual('source', self.classify('rode', 'rel/overlays/bin/seed'))

    def test_marquee_release_env_and_git_hook_are_source(self):
        for path in ('rel/env.sh.eex', '.githooks/pre-commit'):
            self.assertEqual('source', self.classify('marquee', path), path)


if __name__ == '__main__':
    unittest.main()
