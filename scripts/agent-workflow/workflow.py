"""Read-only maintenance previews and explicit, preflighted harness updates."""
import argparse
import difflib
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

import installer
from repo_policies import REPO_POLICIES

BASE = Path(__file__).resolve().parent
ACTIVATION_HELP = (
    'Native activation UNKNOWN: host trust and hook invocation remain unverified. '
    'File integrity and a successful apply do not verify native activation. '
    'See scripts/agent-workflow/MAINTENANCE.md for host validation.'
)
STATUS_HELP = (
    'current: generated content and installer provenance match.\n'
    'update: generated content or installer provenance differs; use diff to preview.\n'
    'drift: installed files differ from their manifest hashes; use diff and '
    'reconcile local changes before apply, following scripts/agent-workflow/MAINTENANCE.md.\n'
    'missing: the harness manifest is absent. error: inspection could not complete.\n'
    'Provenance compares bundled component content, independently of Git HEAD.\n\n' + ACTIVATION_HELP
)


def git(root, *arguments):
    result = subprocess.run(['git', '-C', str(root), *arguments],
                            env={**os.environ, 'GIT_OPTIONAL_LOCKS': '0'},
                            capture_output=True, text=True)
    if result.returncode:
        raise ValueError(result.stderr.strip() or 'Git inspection failed')
    return result.stdout


def release_metadata():
    release = json.loads((BASE / 'release.json').read_text())
    if not isinstance(release, dict):
        raise ValueError('Installer release must be an object')
    version = release.get('installer_version')
    if not isinstance(version, str) or not re.fullmatch(r'\d+\.\d+\.\d+', version):
        raise ValueError('Invalid installer release version')
    digest = hashlib.sha256()
    inputs = list(BASE.glob('*.py')) + [BASE / 'release.json']
    bundle = BASE.parent.parent
    for name in ('app-template', 'app-template-ruby', 'app-template-rails', 'app-template-zola', 'app-template-react'):
        template = bundle / name
        inputs.extend(p for p in template.rglob('*') if p.is_file() and
                      (p.name in ('CLAUDE.md', 'claude-docs.manifest') or
                       any(part in ('.claude', '.docs') for part in p.relative_to(template).parts)) and
                      '__pycache__' not in p.parts and p.suffix != '.pyc')
    for path in sorted(inputs):
        label = str(path.relative_to(bundle)) if path.is_relative_to(bundle) else path.name
        data = path.read_bytes()
        digest.update(label.encode() + b'\0' + str(len(data)).encode() + b'\0' + data)
    return {'version': version, 'source_commit': digest.hexdigest(), 'dirty': False}


def target_root(base, name):
    if name not in REPO_POLICIES:
        raise ValueError('Unknown repository: ' + name)
    root = base / name
    # Do not resolve through aliases before checking the requested location.
    for path in (root, *root.parents):
        if path.is_symlink():
            raise ValueError('Symlink repository path: ' + str(path))
    if not root.is_dir():
        raise ValueError('Missing repository: ' + str(root))
    if Path(git(root, 'rev-parse', '--show-toplevel').strip()).resolve() != root.resolve():
        raise ValueError('Target must be a Git checkout root: ' + str(root))
    return root.resolve()


def inspect(base, name, metadata):
    entry = {'name': name, 'path': str(base / name), 'status': 'error',
             'native_activation': 'UNKNOWN', 'changed_files': [], 'drift_files': []}
    try:
        root = target_root(base, name)
        if (root / '.agent-docs-manifest.json').exists():
            raise ValueError('Target is managed by agent-docs.sh; use agent-docs.sh check|diff|update TARGET')
        # Validate every possible managed location before reading any configuration.
        for rel in installer.MANAGED_PATHS:
            installer.safe_destination(root, rel)
        plan = installer.render(root, REPO_POLICIES[name], installer_metadata={
            key: metadata[key] for key in ('version', 'source_commit')})
        changes = sorted(rel for rel, content in plan['files'].items()
                         if not (root / rel).exists() or (root / rel).read_bytes() != content.encode())
        drift = plan['report']['previous_drift']
        entry.update(changed_files=changes, drift_files=drift)
        entry['status'] = ('drift' if drift else
                           'missing' if not (root / installer.MANIFEST_PATH).exists() else
                           'update' if changes else 'current')
        return entry, root, plan
    except (ValueError, OSError, TypeError) as error:
        entry['error'] = str(error)
        return entry, None, None


def managed_git_edits(root):
    candidates = sorted(installer.MANAGED_PATHS)
    paths = set()
    for args in (('diff', '--name-only', '-z'),
                 ('diff', '--cached', '--name-only', '-z'),
                 ('ls-files', '--others', '-z')):
        paths.update(filter(None, git(root, *args, '--', *candidates).split('\0')))
    return sorted(paths)


def emit(result, plans, json_output):
    if json_output:
        print(json.dumps(result, indent=2, sort_keys=True))
        return
    metadata = result['installer']
    if metadata:
        print(f"Installer {metadata['version']} at {metadata['source_commit']}"
              + (' (dirty preview)' if metadata['dirty'] else ''))
    for entry, root, plan in plans:
        print(f"{entry['name']}: {entry['status']} (native activation UNKNOWN)")
        if entry['status'] == 'update':
            print('  Generated content or installer provenance differs; use diff to preview.')
        if entry['changed_files']:
            label = 'Changed files (applied)' if result['command'] == 'apply' and entry['status'] == 'current' else 'Changed files'
            print('  ' + label + ':')
            for rel in entry['changed_files']:
                print('    ' + rel)
        if entry['drift_files']:
            print('  Drift files:')
            for rel in entry['drift_files']:
                print('    ' + rel)
            print('  Use diff to review; reconcile local changes before apply. See scripts/agent-workflow/MAINTENANCE.md.')
        if entry.get('error'):
            print(entry['error'])
        if result['command'] == 'diff' and plan:
            for rel in entry['changed_files']:
                old = (root / rel).read_text() if (root / rel).exists() else ''
                print(''.join(difflib.unified_diff(
                    old.splitlines(keepends=True), plan['files'][rel].splitlines(keepends=True),
                    fromfile=str(root / rel), tofile=str(root / rel))), end='')
    if result.get('error'):
        print(result['error'])
    print(ACTIVATION_HELP)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, epilog=STATUS_HELP,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('command', choices=('check', 'diff', 'apply'))
    default_root = BASE.parent.parent.parent if BASE.name == 'agent-workflow' else BASE.parent
    parser.add_argument('--root', type=Path, default=default_root,
                        help='Directory containing the registered repositories')
    selection = parser.add_mutually_exclusive_group()
    selection.add_argument('--repo', action='append', help='Explicit repository name; repeat as needed')
    selection.add_argument('--all', action='store_true', help='Select all registered repositories')
    parser.add_argument('--json', action='store_true', help='Emit structured results')
    args = parser.parse_args(argv)
    names = sorted(REPO_POLICIES) if args.all else list(dict.fromkeys(args.repo or []))
    result = {'command': args.command, 'repositories': [], 'installer': {}}
    plans = []
    try:
        metadata = release_metadata()
        result['installer'] = metadata
        if not names:
            raise ValueError('Select --repo NAME or --all explicitly')
        base = args.root.absolute()
        plans = [inspect(base, name, metadata) for name in names]
        result['repositories'] = [item[0] for item in plans]
        if any(entry['status'] == 'error' for entry, _, _ in plans):
            exit_code = 2
        elif args.command == 'apply':
            blockers = []
            if metadata['dirty']:
                blockers.append('Installer source is dirty; commit the release before applying')
            for entry, root, plan in plans:
                if entry['drift_files']:
                    blockers.append(entry['name'] + ': manifest drift blocks apply')
                if entry['changed_files']:
                    edits = managed_git_edits(root)
                    if edits:
                        blockers.append(entry['name'] + ': uncommitted managed files: ' + ', '.join(edits))
            if blockers:
                result['error'] = '; '.join(blockers)
                exit_code = 2
            else:
                # Every selected checkout has passed preflight before the first write.
                for entry, root, plan in plans:
                    for rel in entry['changed_files']:
                        path = installer.safe_destination(root, rel)
                        path.parent.mkdir(parents=True, exist_ok=True)
                        path.write_text(plan['files'][rel])
                    entry['status'] = 'current'
                exit_code = 0
        else:
            exit_code = int(any(entry['status'] != 'current' for entry, _, _ in plans))
    except (ValueError, OSError, TypeError) as error:
        result['error'] = str(error)
        exit_code = 2
    emit(result, plans, args.json)
    return exit_code


if __name__ == '__main__':
    sys.exit(main())
