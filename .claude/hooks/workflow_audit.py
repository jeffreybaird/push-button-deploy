"""Audit log for Bash: record which role changed which files. Never blocks or grants."""
import argparse
from datetime import datetime, timezone
import difflib
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys
import time

LOG = '.agent-audit/bash.jsonl'
EXCLUDED_PREFIX = '.agent-audit/'
MAX_DIFF_LINES = 200
STALE_SECONDS = 24 * 60 * 60
POST_EVENTS = {'PostToolUse': 'success', 'PostToolUseFailure': 'failure'}

_spec = importlib.util.spec_from_file_location('_audit_workflow_guard', Path(__file__).resolve().parent / 'workflow_guard.py')
guard = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(guard)


def git(root, *args, stdin=None, check=True):
    result = subprocess.run(['git', *args], cwd=root, input=stdin, capture_output=True, check=False)
    if check and result.returncode:
        raise RuntimeError('git ' + args[0] + ' failed')
    return result


def head_of(root):
    result = git(root, 'rev-parse', '--verify', '-q', 'HEAD', check=False)
    return result.stdout.decode().strip() or None


def dirty_paths(root):
    """Tracked changes plus untracked, non-ignored files, as repo-relative paths."""
    fields = git(root, 'status', '--porcelain=v1', '-z', '--untracked-files=all').stdout.decode().split('\0')
    paths, index = set(), 0
    while index < len(fields):
        entry = fields[index]
        index += 1
        if not entry:
            continue
        paths.add(entry[3:])
        if entry[0] in 'RC':
            paths.add(fields[index])
            index += 1
    return {p for p in paths if not p.startswith(EXCLUDED_PREFIX)}


def stored_blobs(root, paths):
    """Write current contents to the object store; absent files map to None."""
    present = sorted(p for p in paths if (root / p).is_file())
    blobs = dict.fromkeys(paths)
    if present:
        output = git(root, 'hash-object', '-w', '--stdin-paths', stdin='\n'.join(present).encode()).stdout.decode()
        blobs.update(zip(present, output.split()))
    return blobs


def current_blob(root, path):
    if not (root / path).is_file():
        return None
    return git(root, 'hash-object', '--', path).stdout.decode().strip()


def blob_at(root, commit, path):
    if not commit:
        return None
    result = git(root, 'rev-parse', '--verify', '-q', commit + ':' + path, check=False)
    return result.stdout.decode().strip() or None


def paths_changed_between(root, before, after):
    if not before or not after or before == after:
        return set()
    output = git(root, 'diff', '--name-only', '-z', before, after).stdout.decode()
    return {p for p in output.split('\0') if p and not p.startswith(EXCLUDED_PREFIX)}


def pending_dir(root):
    raw = git(root, 'rev-parse', '--git-path', 'agent-audit').stdout.decode().strip()
    path = Path(raw) if Path(raw).is_absolute() else root / raw
    path.mkdir(parents=True, exist_ok=True)
    return path


def pending_name(tool_use_id):
    if not isinstance(tool_use_id, str) or not tool_use_id:
        raise ValueError('Missing tool_use_id')
    return re.sub(r'[^A-Za-z0-9_-]', '_', tool_use_id) + '.json'


def discard_stale_snapshots(folder):
    cutoff = time.time() - STALE_SECONDS
    for snapshot in folder.glob('*.json'):
        if snapshot.stat().st_mtime < cutoff:
            snapshot.unlink(missing_ok=True)


def record_snapshot(root, event):
    folder = pending_dir(root)
    discard_stale_snapshots(folder)
    snapshot = {'tool_use_id': event['tool_use_id'], 'head': head_of(root),
                'files': stored_blobs(root, dirty_paths(root))}
    (folder / pending_name(event['tool_use_id'])).write_text(json.dumps(snapshot))


def text_of_blob(root, blob):
    return '' if blob is None else git(root, 'cat-file', 'blob', blob).stdout.decode('utf-8')


def text_of_file(root, path):
    return (root / path).read_bytes().decode('utf-8') if (root / path).is_file() else ''


def describe_diff(root, path, before, change):
    try:
        old, new = text_of_blob(root, before), text_of_file(root, path)
    except UnicodeDecodeError:
        return {'binary': True}
    lines = list(difflib.unified_diff(old.splitlines(), new.splitlines(),
                                      'a/' + path if before else '/dev/null',
                                      'b/' + path if change != 'deleted' else '/dev/null', lineterm=''))
    return {'diff': '\n'.join(lines[:MAX_DIFF_LINES]), 'diff_truncated': len(lines) > MAX_DIFF_LINES}


def owner_accepts(category, role):
    return category is None or role == ('spec_writer' if category == 'test' else 'implementer')


def file_changes(root, snapshot, policy, role):
    head_after = head_of(root)
    candidates = set(snapshot['files']) | dirty_paths(root) | paths_changed_between(root, snapshot['head'], head_after)
    changes = []
    for path in sorted(candidates):
        before = snapshot['files'][path] if path in snapshot['files'] else blob_at(root, snapshot['head'], path)
        after = current_blob(root, path)
        if before == after:
            continue
        change = 'added' if before is None else 'deleted' if after is None else 'modified'
        category = guard.classification(root / path, root, policy)
        record = {'path': path, 'change': change, 'class': category, 'owner_ok': owner_accepts(category, role)}
        if category:
            record.update(describe_diff(root, path, before, change))
        changes.append(record)
    return head_after, changes


def role_label(event):
    if not event.get('agent_id'):
        return 'main'
    return guard.role_of(event)


def record_outcome(root, event, policy):
    folder = pending_dir(root)
    snapshot_path = folder / pending_name(event['tool_use_id'])
    if not snapshot_path.exists():
        return
    snapshot = json.loads(snapshot_path.read_text())
    role = role_label(event)
    head_after, changes = file_changes(root, snapshot, policy, role)
    snapshot_path.unlink(missing_ok=True)
    if not changes:
        return
    overlapping = sorted(p.stem for p in folder.glob('*.json'))
    entry = {'timestamp': datetime.now(timezone.utc).isoformat(timespec='seconds'),
             'session_id': event.get('session_id'), 'tool_use_id': event['tool_use_id'],
             'agent_id': event.get('agent_id'), 'agent_type': event.get('agent_type'), 'role': role,
             'command': (event.get('tool_input') or {}).get('command'),
             'outcome': POST_EVENTS[event['hook_event_name']],
             'head_before': snapshot['head'], 'head_after': head_after,
             'overlapping_tool_use_ids': overlapping, 'changes': changes,
             'violations': [c['path'] for c in changes if not c['owner_ok']]}
    log = root / LOG
    log.parent.mkdir(parents=True, exist_ok=True)
    with log.open('a') as handle:
        handle.write(json.dumps(entry, sort_keys=True) + '\n')


def handle(event, root, policy):
    if not isinstance(event, dict) or event.get('tool_name') != 'Bash':
        return
    name = event.get('hook_event_name')
    if name not in ('PreToolUse', *POST_EVENTS):
        return
    root = guard.repository_root(root)
    if git(root, 'rev-parse', '--show-toplevel', check=False).returncode:
        return
    if name == 'PreToolUse':
        record_snapshot(root, event)
    else:
        record_outcome(root, event, guard.validate_policy(policy))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', required=True)
    parser.add_argument('--policy', required=True)
    args = parser.parse_args()
    try:
        event = json.load(sys.stdin)
        handle(event, args.root, json.loads(Path(args.policy).read_text()))
    except Exception as exc:  # An audit failure must never block or alter the tool call.
        print('workflow audit skipped: ' + type(exc).__name__, file=sys.stderr)
    print('{}')


if __name__ == '__main__':
    main()
