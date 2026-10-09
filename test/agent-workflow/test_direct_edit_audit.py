"""Declared direct edit mutations share the source/test audit log with Bash."""
import json
from pathlib import Path
import subprocess
import unittest

import test_codex_audit_privacy as privacy_contract


class DirectEditAudit(unittest.TestCase):
    setUp = privacy_contract.AuditMarkerPrivacy.setUp
    hook = privacy_contract.AuditMarkerPrivacy.hook

    def event_for(self, phase, tool='apply_patch', identity='edit-1', payload=None, **metadata):
        return {'hook_event_name': phase, 'tool_name': tool, 'tool_use_id': identity,
                'session_id': 'edit-session', 'agent_id': 'edit-agent',
                'agent_type': 'workflow_implementer', 'model': 'runtime-edit-model',
                'tool_input': payload or {'command': '*** Begin Patch\n*** Update File: src/app.py\n@@\n-value = 1\n+value = 2\n*** End Patch'},
                'tool_response': {'exit_code': 0}, **metadata}

    def finish(self, platform, pre, post=None):
        self.hook(platform, post or {**pre, 'hook_event_name': 'PostToolUse'})

    def assert_note(self, entry, paths, added=0, modified=0, deleted=0):
        self.assertEqual(
            f'Changed {len(paths)} paths ({added} added, {modified} modified, {deleted} deleted): '
            + ', '.join(paths), entry['note'])

    def assert_private_blob_absent(self, contents):
        digest = subprocess.run(['git', 'hash-object', '--stdin'], input=contents,
                                cwd=self.root, capture_output=True, text=True, check=True).stdout.strip()
        self.assertNotEqual(0, subprocess.run(['git', 'cat-file', '-e', digest], cwd=self.root,
                                            capture_output=True).returncode)

    def pending(self, identity):
        folder = Path(self.fixture.git('rev-parse', '--absolute-git-dir')) / 'agent-audit'
        return json.loads((folder / f'{identity}.json').read_text())

    def test_codex_patch_records_runtime_identity_and_scoped_diff(self):
        pre = self.event_for('PreToolUse')
        self.hook('codex', pre)
        (self.root / 'src/app.py').write_text('value = 2\n')
        self.finish('codex', pre)
        entry = self.fixture.entry()
        self.assertEqual(('apply_patch', 'runtime-edit-model', 'edit-agent', 'implementer', 'success'),
                         (entry['tool_name'], entry['model'], entry['agent_id'], entry['role'], entry['outcome']))
        self.assertIsNone(entry['command'])
        self.assertEqual([], entry['violations'])
        self.assertEqual(['src/app.py'], [c['path'] for c in entry['changes']])
        self.assertIn('-value = 1', entry['changes'][0]['diff'])
        self.assertIn('+value = 2', entry['changes'][0]['diff'])
        self.assert_note(entry, ['src/app.py'], modified=1)

    def test_claude_write_edit_notebook_record_declared_scoped_paths(self):
        for index, tool in enumerate(('Write', 'Edit', 'NotebookEdit')):
            with self.subTest(tool=tool):
                key = 'notebook_path' if tool == 'NotebookEdit' else 'file_path'
                pre = self.event_for('PreToolUse', tool, f'claude-{index}',
                                     {key: str(self.root / 'src/app.py'), 'content': 'private tool text'})
                self.hook('claude', pre)
                (self.root / 'src/app.py').write_text(f'value = {index + 20}\n')
                self.finish('claude', pre)
                entry = self.fixture.entries()[-1]
                self.assertEqual(tool, entry['tool_name'])
                self.assertEqual('runtime-edit-model', entry['model'])
                self.assertEqual('edit-agent', entry['agent_id'])
                self.assertEqual('implementer', entry['role'])
                self.assertEqual('success', entry['outcome'])
                self.assertIsNone(entry['command'])
                self.assertNotIn('private tool text', json.dumps(entry))
                self.assert_note(entry, ['src/app.py'], modified=1)
        self.assertEqual(3, len(self.fixture.entries()))

    def test_add_delete_move_are_sorted_and_count_actual_mutations(self):
        patch = ('*** Begin Patch\n*** Add File: tests/new.py\n+assert True\n'
                 '*** Delete File: tests/test_app.py\n'
                 '*** Update File: src/app.py\n*** Move to: src/moved.py\n@@\n'
                 '-value = 1\n+value = 2\n*** End Patch')
        pre = self.event_for('PreToolUse', payload={'command': patch}, agent_type='workflow_spec_writer')
        self.hook('codex', pre)
        (self.root / 'tests/new.py').write_text('assert True\n')
        (self.root / 'tests/test_app.py').unlink()
        (self.root / 'src/app.py').unlink()
        (self.root / 'src/moved.py').write_text('value = 2\n')
        self.finish('codex', pre)
        entry = self.fixture.entry()
        self.assertEqual([('src/app.py', 'deleted'), ('src/moved.py', 'added'),
                          ('tests/new.py', 'added'), ('tests/test_app.py', 'deleted')],
                         [(c['path'], c['change']) for c in entry['changes']])
        self.assertEqual(['src/app.py', 'src/moved.py'], entry['violations'])
        self.assert_note(entry, ['src/app.py', 'src/moved.py', 'tests/new.py', 'tests/test_app.py'],
                         added=2, deleted=2)

    def test_dirty_declared_baseline_is_exact_and_other_agent_changes_are_excluded(self):
        (self.root / 'src/app.py').write_text('value = 10\n')
        (self.root / 'tests/test_app.py').write_text('assert 10\n')
        pre = self.event_for('PreToolUse')
        self.hook('codex', pre)
        (self.root / 'src/app.py').write_text('value = 11\n')
        (self.root / 'tests/test_app.py').write_text('assert 11\n')
        (self.root / 'src/unrelated.py').write_text('other agent\n')
        self.finish('codex', pre)
        entry = self.fixture.entry()
        self.assertEqual(['src/app.py'], [c['path'] for c in entry['changes']])
        self.assertIn('-value = 10', entry['changes'][0]['diff'])
        self.assertNotIn('-value = 1\n', entry['changes'][0]['diff'])

    def test_metadata_falls_back_to_pre_and_completion_is_authoritative(self):
        for platform, tool in (('codex', 'apply_patch'), ('claude', 'Write')):
            for index, override in enumerate((False, True)):
                with self.subTest(platform=platform, override=override):
                    payload = None if platform == 'codex' else {'file_path': 'src/app.py'}
                    pre = self.event_for('PreToolUse', tool, f'{platform}-metadata-{index}', payload)
                    self.hook(platform, pre)
                    (self.root / 'src/app.py').write_text(f'{platform} value = {index}\n')
                    post = {key: value for key, value in pre.items()
                            if key not in ('tool_input', 'agent_id', 'agent_type', 'model', 'session_id')}
                    post['hook_event_name'] = 'PostToolUse'
                    if override:
                        post.update(model='completion-model', agent_id='completion-agent',
                                    agent_type='workflow_spec_writer')
                    self.finish(platform, pre, post)
                    entry = self.fixture.entries()[-1]
                    self.assertEqual('completion-model' if override else 'runtime-edit-model', entry['model'])
                    self.assertEqual('completion-agent' if override else 'edit-agent', entry['agent_id'])
                    self.assertEqual('spec_writer' if override else 'implementer', entry['role'])

    def test_missing_model_and_agent_id_are_null_and_explicit_post_null_is_authoritative(self):
        for index, null_post in enumerate((False, True)):
            with self.subTest(null_post=null_post):
                pre = self.event_for('PreToolUse', identity=f'null-{index}')
                if not null_post:
                    pre.pop('model')
                    pre.pop('agent_id')
                self.hook('codex', pre)
                (self.root / 'src/app.py').write_text(f'value = {index + 30}\n')
                post = {**pre, 'hook_event_name': 'PostToolUse', 'model': None, 'agent_id': None}
                self.finish('codex', pre, post)
                entry = self.fixture.entries()[-1]
                self.assertIsNone(entry['model'])
                self.assertIsNone(entry['agent_id'])

    def test_noop_failed_and_denied_without_mutation_have_no_entry(self):
        for index, response in enumerate(({'exit_code': 0}, {'exit_code': 1}, {'exit_code': 2})):
            pre = self.event_for('PreToolUse', identity=f'noop-{index}')
            self.hook('codex', pre)
            self.finish('codex', pre, {**pre, 'hook_event_name': 'PostToolUse', 'tool_response': response})
        denied = self.event_for('PreToolUse', identity='denied-no-post')
        self.hook('codex', denied)
        self.assertEqual([], self.fixture.entries())

    def test_failed_tool_with_actual_mutation_logs_failure(self):
        for index, platform in enumerate(('codex', 'claude')):
            tool = 'apply_patch' if platform == 'codex' else 'Edit'
            payload = None if platform == 'codex' else {'file_path': 'src/app.py'}
            pre = self.event_for('PreToolUse', tool, f'failed-{platform}', payload)
            self.hook(platform, pre)
            (self.root / 'src/app.py').write_text(f'value = {index + 40}\n')
            post = {**pre, 'hook_event_name': 'PostToolUse' if platform == 'codex' else 'PostToolUseFailure',
                    'tool_response': {'exit_code': 1}}
            self.finish(platform, pre, post)
            self.assertEqual('failure', self.fixture.entries()[-1]['outcome'])

    def test_unscoped_and_ignored_direct_edits_never_store_private_bytes(self):
        (self.root / '.gitignore').write_text('src/ignored.py\n')
        for index, target in enumerate(('private.txt', 'src/ignored.py')):
            (self.root / target).write_text('private baseline\n')
            pre = self.event_for('PreToolUse', 'Write', f'private-{index}', {'file_path': target})
            self.hook('claude', pre)
            (self.root / target).write_text('private completion\n')
            self.finish('claude', pre)
        self.assertEqual([], self.fixture.entries())
        # hash-object without -w gives the content ID without storing private bytes.
        digest = subprocess.run(['git', 'hash-object', '--stdin'], input='private baseline\n',
                                cwd=self.root, capture_output=True, text=True, check=True).stdout.strip()
        self.assertNotEqual(0, subprocess.run(['git', 'cat-file', '-e', digest], cwd=self.root,
                                            capture_output=True).returncode)

    def test_outside_and_symlink_targets_never_read_or_store_private_bytes(self):
        outside = self.root.parent / (self.root.name + '-private.py')
        outside.write_text('outside private baseline\n')
        self.addCleanup(outside.unlink, missing_ok=True)
        alias = self.root / 'src/alias.py'
        alias.symlink_to(outside)
        for index, target in enumerate((str(outside), 'src/alias.py')):
            baseline = outside.read_text()
            pre = self.event_for('PreToolUse', 'Write', f'outside-{index}', {'file_path': target})
            self.hook('claude', pre)
            self.assert_private_blob_absent(baseline)
            self.assertNotIn('outside private', json.dumps(self.pending(f'outside-{index}')))
            outside.write_text(f'outside private changed {index}\n')
            self.finish('claude', pre)
            self.assert_private_blob_absent(baseline)
            self.assert_private_blob_absent(outside.read_text())
        self.assertEqual([], self.fixture.entries())

    def test_declared_source_replaced_with_outside_symlink_never_reads_target(self):
        outside = self.root.parent / (self.root.name + '-replacement-private.py')
        outside.write_text('replacement outside private bytes\n')
        self.addCleanup(outside.unlink, missing_ok=True)
        pre = self.event_for('PreToolUse')
        self.hook('codex', pre)
        (self.root / 'src/app.py').unlink()
        (self.root / 'src/app.py').symlink_to(outside)
        self.finish('codex', pre)
        self.assert_private_blob_absent(outside.read_text())
        raw = json.dumps(self.fixture.entries())
        self.assertNotIn('replacement outside private bytes', raw)
        self.assertNotIn(str(outside), raw)
        for entry in self.fixture.entries():
            self.assertEqual(['src/app.py'], [change['path'] for change in entry['changes']])
            self.assertEqual('deleted', entry['changes'][0]['change'])

    def test_pending_direct_markers_keep_only_metadata_and_declared_scoped_snapshots(self):
        (self.root / 'src/unrelated.py').write_text('unrelated private baseline\n')
        cases = (
            ('codex', 'apply_patch', {'command': '*** Begin Patch\n*** Update File: src/app.py\n@@\n'
             '-value = 1\n+raw-patch-private-value\n*** Add File: private.txt\n+noncode-private-value\n*** End Patch'}),
            ('claude', 'Write', {'file_path': 'src/app.py', 'content': 'write-private-value'}),
            ('claude', 'Edit', {'file_path': 'src/app.py', 'old_string': 'edit-private-old',
                                'new_string': 'edit-private-new'}),
            ('claude', 'NotebookEdit', {'notebook_path': 'src/app.py', 'new_source': 'notebook-private-value'}),
        )
        for index, (platform, tool, payload) in enumerate(cases):
            with self.subTest(tool=tool):
                identity = f'pending-private-{index}'
                pre = self.event_for('PreToolUse', tool, identity, payload)
                self.hook(platform, pre)
                marker = self.pending(identity)
                self.assertEqual({'tool_use_id', 'tool', 'started', 'head', 'files', 'context'}, set(marker))
                self.assertEqual({'agent_id': 'edit-agent', 'agent_type': 'workflow_implementer',
                                  'session_id': 'edit-session', 'model': 'runtime-edit-model'}, marker['context'])
                self.assertEqual({'src/app.py'}, set(marker['files']))
                raw = json.dumps(marker)
                for private in ('raw-patch-private-value', 'noncode-private-value', 'write-private-value',
                                'edit-private-old', 'edit-private-new', 'notebook-private-value',
                                'unrelated private baseline', 'private.txt'):
                    self.assertNotIn(private, raw)
                self.assert_private_blob_absent('unrelated private baseline\n')
                self.finish(platform, pre)
        self.assertEqual([], self.fixture.entries())

    def test_completed_claude_bash_marker_also_keeps_only_timing(self):
        pre = self.event_for('PreToolUse', 'Bash', 'claude-bash', {'command': 'sensitive command'})
        self.hook('claude', pre)
        (self.root / 'src/app.py').write_text('value = 2\n')
        self.finish('claude', pre)
        folder = Path(self.fixture.git('rev-parse', '--absolute-git-dir')) / 'agent-audit'
        done = json.loads((folder / 'done/claude-bash.json').read_text())
        self.assertEqual({'tool_use_id', 'tool', 'started', 'ended'}, set(done))

    def test_completed_direct_markers_keep_only_timing_for_both_platforms(self):
        for platform, tool, payload in (
                ('codex', 'apply_patch', None), ('claude', 'Write', {'file_path': 'src/app.py', 'content': 'private-input'})):
            pre = self.event_for('PreToolUse', tool, f'minimized-{platform}', payload)
            self.hook(platform, pre)
            (self.root / 'src/app.py').write_text(f'value = "{platform}"\n')
            self.finish(platform, pre)
            folder = Path(self.fixture.git('rev-parse', '--absolute-git-dir')) / 'agent-audit'
            self.assertFalse((folder / f'minimized-{platform}.json').exists())
            done = json.loads((folder / 'done' / f'minimized-{platform}.json').read_text())
            self.assertEqual({'tool_use_id', 'tool', 'started', 'ended'}, set(done))

    def test_large_direct_diff_is_bounded(self):
        pre = self.event_for('PreToolUse')
        self.hook('codex', pre)
        (self.root / 'src/app.py').write_text('value = 2\n' * 500)
        self.finish('codex', pre)
        change = self.fixture.entry()['changes'][0]
        self.assertTrue(change['diff_truncated'])
        self.assertLessEqual(len(change['diff'].splitlines()), 200)

    def test_overlap_is_conservative_and_later_unchanged_bash_does_not_duplicate(self):
        self.fixture.hook('PreToolUse', identity='overlap-shell')
        pre = self.event_for('PreToolUse')
        self.hook('codex', pre)
        (self.root / 'src/app.py').write_text('value = 2\n')
        self.finish('codex', pre)
        entry = self.fixture.entry()
        self.assertEqual(['overlap-shell'], entry['overlapping_tool_use_ids'])
        self.assertEqual('ambiguous', entry['attribution'])
        self.fixture.hook('PostToolUse', identity='overlap-shell', response={'exit_code': 0})
        self.assertEqual(2, len(self.fixture.entries()))
        self.fixture.hook('PreToolUse', identity='later-unchanged-shell')
        self.fixture.hook('PostToolUse', identity='later-unchanged-shell', response={'exit_code': 0})
        self.assertEqual(2, len(self.fixture.entries()))

    def test_bash_rows_have_tool_name_and_deterministic_note(self):
        self.fixture.hook('PreToolUse')
        (self.root / 'src/app.py').write_text('value = 2\n')
        self.fixture.hook('PostToolUse', response={'exit_code': 0})
        entry = self.fixture.entry()
        self.assertEqual('Bash', entry['tool_name'])
        self.assert_note(entry, ['src/app.py'], modified=1)


if __name__ == '__main__':
    unittest.main()
