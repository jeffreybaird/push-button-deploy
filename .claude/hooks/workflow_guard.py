"""Direct source/test edit ownership; all other operations retain native permissions."""
import argparse
import fnmatch
import json
import os
from pathlib import Path
import stat
import sys

ROLES = ('spec_writer', 'implementer', 'runner', 'reviewer', 'orchestrator')
VERSION = '2.0.0'


def deny(reason):
    return {"hookSpecificOutput": {"hookEventName": "PreToolUse",
            "permissionDecision": "deny", "permissionDecisionReason": reason}}


def relative_parts(raw):
    if not isinstance(raw, str) or not raw or any(ord(c) < 32 for c in raw) or "\\" in raw:
        raise ValueError('Invalid path')
    parts = raw.split('/')
    if any(p in ('.', '..') for p in parts) or '' in parts[1:]:
        raise ValueError('Noncanonical policy path')
    return parts


def validate_policy(policy):
    if not isinstance(policy, dict) or policy.get('schema_version') != 2:
        raise ValueError('Unsupported policy schema')
    for key in ('source_globs', 'test_globs'):
        if not isinstance(policy.get(key), list):
            raise ValueError('Policy requires list: ' + key)
        for raw in policy[key]:
            relative_parts(raw)
            if Path(raw).is_absolute():
                raise ValueError('Policy paths must be relative')
    legacy = policy.get('legacy_commands', [])
    if not isinstance(legacy, list) or any(not isinstance(c, str) or not c.strip() for c in legacy):
        raise ValueError('Legacy commands must be nonempty strings')
    return policy


def repository_root(raw):
    root = Path(raw)
    if not root.is_absolute() or not root.is_dir() or root.resolve() != root:
        raise ValueError('Repository root must be a real canonical absolute directory')
    return root


def role_of(event):
    if any(not isinstance(event.get(k), str) or not event[k].strip() for k in ('agent_id', 'agent_type')):
        return None
    role = event['agent_type'].replace('-', '_')
    if role.startswith('workflow_'):
        role = role[len('workflow_'):]
    return role if role in ROLES else None


def patch_paths(command):
    """Parse the complete canonical patch language, returning all path operands."""
    lines = command.splitlines()
    if not lines or lines[0] != "*** Begin Patch" or lines[-1] != "*** End Patch":
        raise ValueError("Patch must have exact begin/end markers")
    paths, index = [], 1
    while index < len(lines) - 1:
        line = lines[index]
        operation = next((op for op in ("Add File", "Update File", "Delete File")
                          if line.startswith(f"*** {op}: ")), None)
        if operation is None:
            raise ValueError("Unrecognized patch operation")
        paths.append(line[len(f"*** {operation}: "):])
        index += 1
        if operation == "Delete File":
            continue
        if operation == "Add File":
            count = 0
            while index < len(lines) - 1 and lines[index].startswith("+"):
                count += 1
                index += 1
            if not count:
                raise ValueError("Add requires prefixed content")
            continue
        if index < len(lines) - 1 and lines[index].startswith("*** Move to: "):
            paths.append(lines[index][len("*** Move to: "):])
            index += 1
        hunks = 0
        while index < len(lines) - 1 and (lines[index] == "@@" or lines[index].startswith("@@ ")):
            hunks += 1
            index += 1
            count = 0
            while index < len(lines) - 1 and lines[index].startswith((" ", "+", "-")):
                count += 1
                index += 1
            if not count:
                raise ValueError("Update hunk requires prefixed content")
            if index < len(lines) - 1 and lines[index] == "*** End of File":
                index += 1
                break
        if not hunks:
            raise ValueError("Update requires a hunk")
    if not paths:
        raise ValueError("Empty patch")
    return paths



def direct_edit(platform, event):
    if not isinstance(event, dict) or event.get('hook_event_name') != 'PreToolUse':
        return False
    return (platform == 'codex' and event.get('tool_name') == 'apply_patch') or (
        platform == 'claude' and event.get('tool_name') in ('Write', 'Edit', 'NotebookEdit'))


def classification(path, root, policy):
    try:
        rel = path.relative_to(root).as_posix()
    except ValueError:
        return None
    for category, key in (('test', 'test_globs'), ('source', 'source_globs')):
        if any(fnmatch.fnmatchcase(rel, pattern) or
               (pattern.startswith('**/') and fnmatch.fnmatchcase(rel, pattern[3:]))
               for pattern in policy[key]):
            return category
    return None


def authorize_path(raw, root, cwd, role, policy):
    if not isinstance(raw, str) or not raw or any(ord(c) < 32 for c in raw) or "\\" in raw:
        raise ValueError('Missing or invalid direct edit path')
    path = Path(raw)
    path = path if path.is_absolute() else cwd / path
    # Consider both the named path and its physical target so aliases cannot
    # disguise source/test ownership. Outside, unscoped files remain native-controlled.
    lexical = Path(os.path.abspath(path))
    resolved = path.resolve()
    categories = {classification(p, root, policy) for p in (lexical, resolved)} - {None}
    try:
        info = resolved.stat()
    except FileNotFoundError:
        info = None
    if info and stat.S_ISREG(info.st_mode) and info.st_nlink > 1:
        # Hardlinks are uncommon. Only this case needs an inode-alias audit;
        # do not prohibit ordinary unscoped hardlinks merely for being linked.
        for folder, directories, files in os.walk(root, followlinks=False):
            directories[:] = [d for d in directories if not (Path(folder) / d).is_symlink()]
            for name in files:
                alias = Path(folder) / name
                category = classification(alias, root, policy)
                if category and not alias.is_symlink():
                    alias_info = alias.stat()
                    if (alias_info.st_dev, alias_info.st_ino) == (info.st_dev, info.st_ino):
                        categories.add(category)
    for category in categories:
        owner = 'spec_writer' if category == 'test' else 'implementer'
        if role != owner:
            raise ValueError(category.capitalize() + ' edits require ' + owner)
    if categories and info and not stat.S_ISREG(info.st_mode):
        raise ValueError('Scoped edit target must be a file')


def evaluate_event(platform, event, root, policy):
    if not direct_edit(platform, event):
        return {}
    try:
        root = repository_root(root)
        validate_policy(policy)
        payload = event.get('tool_input')
        if not isinstance(payload, dict):
            raise ValueError('Missing native edit input')
        cwd_raw = event.get('cwd', str(root))
        if not isinstance(cwd_raw, str) or not Path(cwd_raw).is_absolute():
            raise ValueError('Invalid edit working directory')
        cwd = Path(cwd_raw).resolve()
        if platform == 'codex':
            if not isinstance(payload.get('command'), str):
                raise ValueError('Missing canonical patch command')
            paths = patch_paths(payload['command'])
        else:
            paths = [payload.get('notebook_path' if event['tool_name'] == 'NotebookEdit' else 'file_path')]
        role = role_of(event)
        for path in paths:
            authorize_path(path, root, cwd, role, policy)
        return {}
    except (ValueError, TypeError, OSError, RuntimeError) as exc:
        return deny(str(exc) or 'Invalid direct edit')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--platform', required=True)
    parser.add_argument('--root', required=True)
    parser.add_argument('--policy', required=True)
    args = parser.parse_args()
    try:
        event = json.load(sys.stdin)
    except (ValueError, OSError, UnicodeError):
        event = None
    result = {}
    if direct_edit(args.platform, event):
        try:
            policy = json.loads(Path(args.policy).read_text())
            result = evaluate_event(args.platform, event, args.root, policy)
        except (ValueError, OSError, UnicodeError) as exc:
            result = deny('Cannot read direct edit policy: ' + str(exc))
    print(json.dumps(result))


if __name__ == '__main__':
    main()
