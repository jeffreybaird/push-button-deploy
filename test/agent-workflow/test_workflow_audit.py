"""Bash audit log: record which role changed which files through shell commands."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

BASE = Path(__file__).resolve().parents[2] / 'scripts' / 'agent-workflow'
AUDIT = BASE / 'workflow_audit.py'
POLICY = {'schema_version': 2, 'source_globs': ['src/*.py'], 'test_globs': ['tests/**']}
LOG = '.agent-audit/bash.jsonl'


def git(root, *args):
    return subprocess.run(['git', *args], cwd=root, check=True, capture_output=True, text=True).stdout


class AuditHook(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        git(self.root, 'init', '-q')
        (self.root / 'src').mkdir()
        (self.root / 'tests').mkdir()
        (self.root / 'src/app.py').write_text('value = 1\n')
        (self.root / 'tests/test_app.py').write_text('assert True\n')
        (self.root / 'README.md').write_text('readme\n')
        (self.root / '.gitignore').write_text('ignored/\n')
        git(self.root, 'add', '.')
        git(self.root, '-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-qm', 'init')
        self.policy = self.root / 'policy.json'
        self.policy.write_text(json.dumps(POLICY))
        git(self.root, 'add', 'policy.json')
        git(self.root, '-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-qm', 'policy')

    def tearDown(self):
        self.temporary.cleanup()

    def hook(self, event, stdin=None):
        result = subprocess.run([sys.executable, '-B', str(AUDIT), '--root', str(self.root), '--policy', str(self.policy)],
                                input=stdin if stdin is not None else json.dumps(event),
                                capture_output=True, text=True, cwd=self.root)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual({}, json.loads(result.stdout))

    def event(self, name, tool_use_id, command, agent_type=None, **extra):
        event = {'hook_event_name': name, 'tool_name': 'Bash', 'tool_use_id': tool_use_id,
                 'session_id': 'session-1', 'cwd': str(self.root), 'tool_input': {'command': command}, **extra}
        if agent_type:
            event.update(agent_id='agent-1', agent_type=agent_type)
        return event

    def run_bash(self, command, agent_type=None, tool_use_id='toolu_1', post='PostToolUse', **extra):
        self.hook(self.event('PreToolUse', tool_use_id, command, agent_type))
        subprocess.run(command, shell=True, cwd=self.root, check=False, capture_output=True)
        self.hook(self.event(post, tool_use_id, command, agent_type, **extra))

    def entries(self):
        log = self.root / LOG
        return [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []

    def only_entry(self):
        entries = self.entries()
        self.assertEqual(1, len(entries), entries)
        return entries[0]

    def change(self, entry, path):
        [change] = [c for c in entry['changes'] if c['path'] == path]
        return change

    def test_records_command_role_and_diff_for_test_edit_by_implementer(self):
        self.run_bash("sed -i.bak 's/True/False/' tests/test_app.py && rm tests/test_app.py.bak",
                      agent_type='workflow-implementer')
        entry = self.only_entry()
        self.assertEqual("sed -i.bak 's/True/False/' tests/test_app.py && rm tests/test_app.py.bak", entry['command'])
        self.assertEqual(('agent-1', 'workflow-implementer', 'implementer'),
                         (entry['agent_id'], entry['agent_type'], entry['role']))
        self.assertEqual(('session-1', 'toolu_1', 'success'),
                         (entry['session_id'], entry['tool_use_id'], entry['outcome']))
        change = self.change(entry, 'tests/test_app.py')
        self.assertEqual(('modified', 'test', False), (change['change'], change['class'], change['owner_ok']))
        self.assertIn('-assert True', change['diff'])
        self.assertIn('+assert False', change['diff'])
        self.assertEqual(['tests/test_app.py'], entry['violations'])
        self.assertIn('T', entry['timestamp'])

    def test_owner_edit_is_recorded_without_violation(self):
        self.run_bash("echo 'value = 2' > src/app.py", agent_type='workflow-implementer')
        entry = self.only_entry()
        self.assertTrue(self.change(entry, 'src/app.py')['owner_ok'])
        self.assertEqual([], entry['violations'])

    def test_completion_runtime_model_is_recorded_for_claude(self):
        self.run_bash("echo 'value = 2' > src/app.py", agent_type='workflow-implementer',
                      model='runtime-claude-model')
        self.assertEqual('runtime-claude-model', self.only_entry()['model'])

    def test_absent_claude_runtime_model_is_null(self):
        self.run_bash("echo 'value = 2' > src/app.py", agent_type='workflow-implementer')
        self.assertIsNone(self.only_entry()['model'])

    def test_command_without_changes_is_not_logged(self):
        self.run_bash('ls && cat README.md', agent_type='workflow-runner')
        self.assertEqual([], self.entries())

    def test_ignored_files_are_not_logged(self):
        self.run_bash('mkdir -p ignored && echo x > ignored/build.out')
        self.assertEqual([], self.entries())

    def test_main_session_identified_as_main(self):
        self.run_bash("echo 'value = 3' > src/app.py")
        entry = self.only_entry()
        self.assertEqual((None, None, 'main'), (entry['agent_id'], entry['agent_type'], entry['role']))
        self.assertEqual(['src/app.py'], entry['violations'])

    def test_new_and_deleted_files(self):
        self.run_bash('echo "def test_x(): pass" > tests/test_new.py && rm src/app.py', agent_type='workflow-spec-writer')
        entry = self.only_entry()
        self.assertEqual('added', self.change(entry, 'tests/test_new.py')['change'])
        self.assertIn('+def test_x(): pass', self.change(entry, 'tests/test_new.py')['diff'])
        deleted = self.change(entry, 'src/app.py')
        self.assertEqual(('deleted', False), (deleted['change'], deleted['owner_ok']))
        self.assertIn('-value = 1', deleted['diff'])

    def test_diff_is_relative_to_state_before_command_not_head(self):
        (self.root / 'src/app.py').write_text('value = 10\n')
        self.run_bash("echo 'value = 11' > src/app.py", agent_type='workflow-implementer')
        diff = self.change(self.only_entry(), 'src/app.py')['diff']
        self.assertIn('-value = 10', diff)
        self.assertNotIn('-value = 1\n', diff)

    def test_command_changing_only_unscoped_files_is_not_logged(self):
        (self.root / 'ignored').mkdir()
        (self.root / 'ignored/secret.txt').write_text('hunter2\n')
        self.run_bash('cp ignored/secret.txt .env.local && echo more >> README.md', agent_type='workflow-reviewer')
        self.assertEqual([], self.entries())

    def test_unscoped_changes_omitted_from_logged_entry(self):
        self.run_bash("echo hunter2 > notes.txt && echo 'value = 8' > src/app.py", agent_type='workflow-implementer')
        entry = self.only_entry()
        self.assertEqual(['src/app.py'], [c['path'] for c in entry['changes']])

    def test_unscoped_dirty_files_never_stored_in_object_database(self):
        (self.root / 'notes.txt').write_text('hunter2 private\n')
        self.run_bash("echo 'value = 9' > src/app.py", agent_type='workflow-implementer')
        blob = git(self.root, 'hash-object', 'notes.txt').strip()
        stored = subprocess.run(['git', 'cat-file', '-e', blob], cwd=self.root, capture_output=True)
        self.assertNotEqual(0, stored.returncode)

    def test_failed_command_still_logged(self):
        self.run_bash("echo 'value = 4' > src/app.py && false", agent_type='workflow-runner',
                      post='PostToolUseFailure', error='Exit code 1', is_interrupt=False)
        entry = self.only_entry()
        self.assertEqual('failure', entry['outcome'])
        self.assertEqual(['src/app.py'], entry['violations'])

    def test_commit_without_content_change_not_logged(self):
        (self.root / 'README.md').write_text('changed before\n')
        self.run_bash('git add README.md && git -c user.name=t -c user.email=t@t commit -qm x')
        self.assertEqual([], self.entries())

    def test_checkout_reverting_test_file_is_logged(self):
        (self.root / 'tests/test_app.py').write_text('assert 1 == 1\n')
        self.run_bash('git checkout -- tests/test_app.py', agent_type='workflow-implementer')
        change = self.change(self.only_entry(), 'tests/test_app.py')
        self.assertEqual(('modified', False), (change['change'], change['owner_ok']))
        self.assertIn('-assert 1 == 1', change['diff'])

    def test_head_moving_to_new_content_is_logged(self):
        git(self.root, 'checkout', '-qb', 'other')
        (self.root / 'src/app.py').write_text('value = 99\n')
        git(self.root, '-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-qam', 'other')
        git(self.root, 'checkout', '-q', '-')
        self.run_bash('git merge -q --ff-only other', agent_type='workflow-reviewer')
        entry = self.only_entry()
        self.assertNotEqual(entry['head_before'], entry['head_after'])
        self.assertIn('+value = 99', self.change(entry, 'src/app.py')['diff'])

    def test_log_appends_and_never_logs_itself(self):
        self.run_bash("echo 'value = 5' > src/app.py", tool_use_id='toolu_a')
        self.run_bash("echo 'value = 6' > src/app.py", tool_use_id='toolu_b')
        entries = self.entries()
        self.assertEqual(['toolu_a', 'toolu_b'], [e['tool_use_id'] for e in entries])
        self.assertTrue(all(c['path'] != LOG for e in entries for c in e['changes']))

    def test_overlapping_calls_are_flagged(self):
        self.hook(self.event('PreToolUse', 'toolu_a', 'sleep 1', 'workflow-runner'))
        self.hook(self.event('PreToolUse', 'toolu_b', "echo 'value = 7' > src/app.py", 'workflow-implementer'))
        (self.root / 'src/app.py').write_text('value = 7\n')
        self.hook(self.event('PostToolUse', 'toolu_b', "echo 'value = 7' > src/app.py", 'workflow-implementer'))
        entry = self.only_entry()
        self.assertEqual(['toolu_a'], entry['overlapping_tool_use_ids'])
        self.assertEqual('ambiguous', entry['attribution'])

    def test_call_alone_is_exclusive(self):
        self.run_bash("echo 'value = 12' > src/app.py", agent_type='workflow-implementer')
        entry = self.only_entry()
        self.assertEqual(([], 'exclusive'), (entry['overlapping_tool_use_ids'], entry['attribution']))

    def test_overlapping_call_that_finished_first_is_flagged(self):
        self.hook(self.event('PreToolUse', 'toolu_long', "echo 'value = 13' > src/app.py", 'workflow-runner'))
        self.hook(self.event('PreToolUse', 'toolu_short', 'true', 'workflow-implementer'))
        self.hook(self.event('PostToolUse', 'toolu_short', 'true', 'workflow-implementer'))
        (self.root / 'src/app.py').write_text('value = 13\n')
        self.hook(self.event('PostToolUse', 'toolu_long', "echo 'value = 13' > src/app.py", 'workflow-runner'))
        self.assertEqual(['toolu_short'], self.only_entry()['overlapping_tool_use_ids'])

    def test_call_finished_before_start_is_not_flagged(self):
        self.run_bash('true', tool_use_id='toolu_before', agent_type='workflow-runner')
        self.run_bash("echo 'value = 14' > src/app.py", tool_use_id='toolu_after', agent_type='workflow-implementer')
        self.assertEqual([], self.only_entry()['overlapping_tool_use_ids'])

    def edit_event(self, name, tool_use_id):
        return {'hook_event_name': name, 'tool_name': 'Edit', 'tool_use_id': tool_use_id, 'session_id': 'session-1',
                'agent_id': 'agent-2', 'agent_type': 'workflow-implementer',
                'tool_input': {'file_path': str(self.root / 'src/app.py')}}

    def test_concurrent_edit_tool_call_is_flagged(self):
        self.hook(self.event('PreToolUse', 'toolu_bash', 'sleep 1', 'workflow-runner'))
        self.hook(self.edit_event('PreToolUse', 'toolu_edit'))
        (self.root / 'src/app.py').write_text('value = 15\n')
        self.hook(self.edit_event('PostToolUse', 'toolu_edit'))
        self.hook(self.event('PostToolUse', 'toolu_bash', 'sleep 1', 'workflow-runner'))
        entries = self.entries()
        self.assertEqual(2, len(entries))
        [entry] = [e for e in entries if e['tool_use_id'] == 'toolu_bash']
        self.assertEqual((['toolu_edit'], ['src/app.py']), (entry['overlapping_tool_use_ids'], entry['violations']))

    def test_edit_tool_call_alone_logs_declared_source_mutation(self):
        self.hook(self.edit_event('PreToolUse', 'toolu_edit'))
        (self.root / 'src/app.py').write_text('value = 16\n')
        self.hook(self.edit_event('PostToolUse', 'toolu_edit'))
        entry = self.only_entry()
        self.assertEqual(('Edit', 'toolu_edit'), (entry['tool_name'], entry['tool_use_id']))
        self.assertEqual(['src/app.py'], [change['path'] for change in entry['changes']])
        self.assertEqual([], entry['violations'])

    def test_edit_that_never_reports_back_expires(self):
        self.hook(self.edit_event('PreToolUse', 'toolu_denied'))
        marker = Path(git(self.root, 'rev-parse', '--absolute-git-dir').strip()) / 'agent-audit/toolu_denied.json'
        data = json.loads(marker.read_text())
        marker.write_text(json.dumps({**data, 'started': data['started'] - 61}))
        self.run_bash("echo 'value = 17' > src/app.py", agent_type='workflow-implementer')
        self.assertEqual([], self.only_entry()['overlapping_tool_use_ids'])

    def test_large_diff_is_truncated(self):
        self.run_bash('python3 -c "print(\'x = 1\\n\' * 5000, end=\'\')" > src/app.py', agent_type='workflow-implementer')
        change = self.change(self.only_entry(), 'src/app.py')
        self.assertTrue(change['diff_truncated'])
        self.assertLessEqual(len(change['diff'].splitlines()), 200)

    def test_post_without_pre_is_ignored(self):
        self.hook(self.event('PostToolUse', 'toolu_missing', 'true', 'workflow-runner'))
        self.assertEqual([], self.entries())

    def test_malformed_input_and_non_bash_abstain(self):
        self.hook(None, stdin='not json')
        self.hook({'hook_event_name': 'PreToolUse', 'tool_name': 'Read', 'tool_use_id': 'x', 'tool_input': {}})
        self.assertEqual([], self.entries())

    def test_non_git_root_abstains(self):
        with tempfile.TemporaryDirectory() as other:
            result = subprocess.run([sys.executable, '-B', str(AUDIT), '--root', str(Path(other).resolve()),
                                     '--policy', str(self.policy)],
                                    input=json.dumps(self.event('PreToolUse', 't', 'true')),
                                    capture_output=True, text=True)
            self.assertEqual((0, '{}'), (result.returncode, result.stdout.strip()))

    def test_pending_snapshots_live_outside_worktree(self):
        self.hook(self.event('PreToolUse', 'toolu_p', 'true'))
        self.assertEqual('', git(self.root, 'status', '--porcelain'))


if __name__ == '__main__':
    unittest.main()
