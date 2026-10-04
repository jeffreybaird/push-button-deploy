"""Audit log for Bash: record source and test changes observed during each call. Never blocks or grants."""
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
EDIT_SECONDS = 60
POST_EVENTS = {'PostToolUse': 'success', 'PostToolUseFailure': 'failure'}
TRACKED_TOOLS = ('Bash', 'Write', 'Edit', 'NotebookEdit')
CODEX_TRACKED_TOOLS = ('Bash', 'apply_patch')

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


def scoped(root, paths, policy):
    """Keep source and test paths only; other files are never read or stored."""
    return {p for p in paths if guard.classification(root / p, root, policy)}


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
    (path / 'done').mkdir(parents=True, exist_ok=True)
    return path


def pending_name(tool_use_id):
    if not isinstance(tool_use_id, str) or not tool_use_id:
        raise ValueError('Missing tool_use_id')
    return re.sub(r'[^A-Za-z0-9_-]', '_', tool_use_id) + '.json'


def discard_stale_snapshots(folder):
    cutoff = time.time() - STALE_SECONDS
    for snapshot in [*folder.glob('*.json'), *(folder / 'done').glob('*.json')]:
        if snapshot.stat().st_mtime < cutoff:
            snapshot.unlink(missing_ok=True)


def record_start(root, event, policy, platform='claude'):
    """Mark a call as running; Bash calls also snapshot dirty source and test files."""
    folder = pending_dir(root)
    discard_stale_snapshots(folder)
    marker = {'tool_use_id': event['tool_use_id'], 'tool': event['tool_name'], 'started': time.time()}
    if event['tool_name'] == 'Bash':
        marker.update(head=head_of(root), files=stored_blobs(root, scoped(root, dirty_paths(root), policy)))
        if platform == 'codex':
            marker['context'] = {key: event[key] for key in
                                 ('agent_id', 'agent_type', 'session_id') if key in event}
            tool_input = event.get('tool_input')
            if isinstance(tool_input, dict) and 'command' in tool_input:
                marker['context']['tool_input'] = {'command': tool_input['command']}
    (folder / pending_name(event['tool_use_id'])).write_text(json.dumps(marker))


def still_running(marker, now):
    """Edits that never report back (a denied Write) stop counting after EDIT_SECONDS."""
    return marker.get('tool') == 'Bash' or now - marker['started'] < EDIT_SECONDS


def overlapping_calls(folder, own_id, started):
    """Calls running at any moment between this call's start and now."""
    now, found = time.time(), set()
    for path in folder.glob('*.json'):
        marker = json.loads(path.read_text())
        if marker['tool_use_id'] != own_id and still_running(marker, now):
            found.add(marker['tool_use_id'])
    for path in (folder / 'done').glob('*.json'):
        marker = json.loads(path.read_text())
        if marker['tool_use_id'] != own_id and marker['ended'] >= started:
            found.add(marker['tool_use_id'])
    return sorted(found)


def record_finish(folder, snapshot_path, marker, platform='claude'):
    if platform == 'codex':
        marker = {key: marker[key] for key in ('tool_use_id', 'tool', 'started')}
    (folder / 'done' / snapshot_path.name).write_text(json.dumps({**marker, 'ended': time.time()}))
    snapshot_path.unlink(missing_ok=True)


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
    return role == ('spec_writer' if category == 'test' else 'implementer')


def file_changes(root, snapshot, policy, role):
    head_after = head_of(root)
    candidates = set(snapshot['files']) | dirty_paths(root) | paths_changed_between(root, snapshot['head'], head_after)
    changes = []
    for path in sorted(scoped(root, candidates, policy)):
        before = snapshot['files'][path] if path in snapshot['files'] else blob_at(root, snapshot['head'], path)
        after = current_blob(root, path)
        if before == after:
            continue
        change = 'added' if before is None else 'deleted' if after is None else 'modified'
        category = guard.classification(root / path, root, policy)
        record = {'path': path, 'change': change, 'class': category, 'owner_ok': owner_accepts(category, role)}
        record.update(describe_diff(root, path, before, change))
        changes.append(record)
    return head_after, changes


def role_label(event, platform='claude'):
    if (platform == 'codex' and 'agent_type' not in event) or not event.get('agent_id'):
        return 'main'
    return guard.role_of(event)


def outcome_of(event, platform):
    if platform == 'claude':
        return POST_EVENTS[event['hook_event_name']]
    response = event.get('tool_response')
    if isinstance(response, str):
        try:
            response = json.loads(response)
        except ValueError:
            return 'unknown'
    if isinstance(response, dict):
        status = response.get('exit_code')
        if type(status) is not int and isinstance(response.get('metadata'), dict):
            status = response['metadata'].get('exit_code')
        if type(status) is int:
            return 'success' if status == 0 else 'failure'
    return 'unknown'


def record_outcome(root, event, policy, platform='claude'):
    folder = pending_dir(root)
    snapshot_path = folder / pending_name(event['tool_use_id'])
    if not snapshot_path.exists():
        return
    snapshot = json.loads(snapshot_path.read_text())
    if snapshot.get('tool') != 'Bash':
        record_finish(folder, snapshot_path, snapshot, platform)
        return
    event = {**snapshot.get('context', {}), **event}
    role = role_label(event, platform)
    head_after, changes = file_changes(root, snapshot, policy, role)
    overlapping = overlapping_calls(folder, snapshot['tool_use_id'], snapshot['started'])
    record_finish(folder, snapshot_path, snapshot, platform)
    if not changes:
        return
    entry = {'timestamp': datetime.now(timezone.utc).isoformat(timespec='seconds'),
             'session_id': event.get('session_id'), 'tool_use_id': event['tool_use_id'],
             'agent_id': event.get('agent_id'), 'agent_type': event.get('agent_type'), 'role': role,
             'command': (event.get('tool_input') or {}).get('command'),
             'outcome': outcome_of(event, platform),
             'head_before': snapshot['head'], 'head_after': head_after,
             'overlapping_tool_use_ids': overlapping,
             'attribution': 'ambiguous' if overlapping else 'exclusive', 'changes': changes,
             'violations': [c['path'] for c in changes if not c['owner_ok']]}
    if platform == 'codex':
        entry['platform'] = platform
    log = root / LOG
    log.parent.mkdir(parents=True, exist_ok=True)
    with log.open('a') as handle:
        handle.write(json.dumps(entry, sort_keys=True) + '\n')


def handle(event, root, policy, platform='claude'):
    tracked = CODEX_TRACKED_TOOLS if platform == 'codex' else TRACKED_TOOLS
    if not isinstance(event, dict) or event.get('tool_name') not in tracked:
        return
    name = event.get('hook_event_name')
    supported = ('PreToolUse', 'PostToolUse') if platform == 'codex' else ('PreToolUse', *POST_EVENTS)
    if name not in supported:
        return
    root = guard.repository_root(root)
    if git(root, 'rev-parse', '--show-toplevel', check=False).returncode:
        return
    policy = guard.validate_policy(policy)
    if name == 'PreToolUse':
        record_start(root, event, policy, platform)
    else:
        record_outcome(root, event, policy, platform)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--platform', choices=('claude', 'codex'), default='claude')
    parser.add_argument('--root', required=True)
    parser.add_argument('--policy', required=True)
    args = parser.parse_args()
    try:
        event = json.load(sys.stdin)
        handle(event, args.root, json.loads(Path(args.policy).read_text()), args.platform)
    except Exception as exc:  # An audit failure must never block or alter the tool call.
        print('workflow audit skipped: ' + type(exc).__name__, file=sys.stderr)
    print('{}')


if __name__ == '__main__':
    main()
