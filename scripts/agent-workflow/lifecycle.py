"""App-local, preservation-aware agent document maintenance. No network or trust edits."""
import argparse
import copy
import difflib
import hashlib
import json
from pathlib import Path
import re
import sys
import tomllib

import installer
import workflow

BUNDLE = Path(__file__).resolve().parents[2]
MANIFEST = '.agent-docs-manifest.json'
GUIDANCE = '.docs/project-guidance.md'
BEGIN = '<!-- BEGIN MANAGED AGENT DOCS -->'
END = '<!-- END MANAGED AGENT DOCS -->'
TEMPLATES = {'phoenix': 'app-template', 'sinatra': 'app-template-ruby', 'rails': 'app-template-rails', 'zola': 'app-template-zola'}
STACKS = {'phoenix': 'service', 'sinatra': 'service', 'rails': 'service', 'zola': 'service',
          'escript': 'cli', 'ruby-cli': 'cli', 'bash-cli': 'cli', 'ts-cli': 'cli', 'mix': 'library'}
DEFAULT_SELECTION = {'skip_modules': [], 'skip_agents': [], 'hook': '', 'no_setup': False}
JSON_CONFIGS = {'.claude/settings.json', '.codex/hooks.json'}


def encoded(value):
    return json.dumps(value, indent=2, sort_keys=True) + '\n'


def digest(text):
    return hashlib.sha256(text.encode()).hexdigest()


def read(root, rel):
    path = installer.safe_destination(root, rel)
    return path.read_text() if path.exists() else ''


def object_json(text, label):
    value = json.loads(text) if text else {}
    if not isinstance(value, dict):
        raise ValueError('Expected an object: ' + label)
    return value


def region(text, begin, end):
    if text.count(begin) != text.count(end) or text.count(begin) > 1:
        raise ValueError('Malformed managed instruction section')
    if begin not in text:
        return ''
    start, stop = text.index(begin), text.index(end)
    if stop < start:
        raise ValueError('Reversed managed instruction section')
    return text[start:stop + len(end)]


def section(text, content):
    old = region(text, BEGIN, END)
    block = BEGIN + '\n' + content.rstrip() + '\n' + END
    if old:
        return text.replace(old, block, 1)
    return text + ('\n' if not text or text.endswith('\n') else '\n\n') + block + '\n'


def template_rows(framework):
    if framework not in TEMPLATES:
        return []
    path = BUNDLE / TEMPLATES[framework] / 'claude-docs.manifest'
    return [line.split('|') for line in path.read_text().splitlines()
            if line and not line.startswith('#')]


def validate_selection(framework, selection):
    if not isinstance(selection, dict) or set(selection) != set(DEFAULT_SELECTION):
        raise ValueError('Invalid recorded selection')
    rows = template_rows(framework)
    for field, role in (('skip_modules', 'optional'), ('skip_agents', 'agent')):
        choices = {row[1] for row in rows if row[0] == role}
        values = selection[field]
        if not isinstance(values, list) or any(not isinstance(v, str) or v not in choices for v in values):
            raise ValueError('Unknown ' + field + ' selection')
    if not isinstance(selection['no_setup'], bool):
        raise ValueError('Invalid cloud setup selection')
    hooks = {row[1] for row in rows if row[0] == 'hook'} | {''}
    if not isinstance(selection['hook'], str) or selection['hook'] not in hooks:
        raise ValueError('Unknown hook variant')


def template_files(framework, selection, names):
    """Render only bundled template files, independently of target contents."""
    if framework not in TEMPLATES:
        title = names['module']
        return {guide: f'# {title}\n\nFramework: {framework}. Application type: {STACKS[framework]}.\n'
                for guide in ('AGENTS.md', 'CLAUDE.md')}
    root = BUNDLE / TEMPLATES[framework]
    tokens = next((row[1:3] for row in template_rows(framework) if row[0] == 'placeholders'), ['MyApp', 'my_app'])
    values = dict(zip(tokens, (names['module'], names['app'])))
    pattern = re.compile('|'.join(re.escape(token) for token in sorted(values, key=len, reverse=True)))
    sources = {'AGENTS.md': root / 'CLAUDE.md', 'CLAUDE.md': root / 'CLAUDE.md'}
    for source in sorted((root / '.claude').glob('*.md')):
        if source.name not in selection['skip_modules']:
            sources['.claude/' + source.name] = source
            sources['doc/' + source.name] = source
    for source in sorted((root / '.claude/agents').glob('*.md')):
        if source.name not in selection['skip_agents']:
            sources['.claude/agents/' + source.name] = source
            sources['doc/agents/' + source.name] = source
    if not selection['no_setup']:
        source = root / '.claude/cloud-setup.sh'
        if source.exists():
            sources['.claude/cloud-setup.sh'] = source
            sources['doc/hooks/cloud-setup.sh'] = source
        suffix = '.' + selection['hook'] + '-hook' if selection['hook'] else ''
        source = root / ('.claude/settings' + suffix + '.json')
        if source.exists():
            sources['.claude/settings.json'] = source
    rendered = {}
    for rel, source in sources.items():
        text = source.read_text()
        if rel == 'AGENTS.md' or rel.startswith('doc/') and rel.endswith('.md'):
            text = text.replace('CLAUDE.md', 'AGENTS.md').replace('.claude/', 'doc/').replace(
                'Claude Code reads this every session.', 'Project guidance for coding agents.')
        if rel == '.claude/settings.json':
            text = text.replace('.claude/cloud-setup.sh', 'doc/hooks/cloud-setup.sh')
        else:
            text = pattern.sub(lambda match: values[match.group()], text)
        if rel in ('AGENTS.md', 'CLAUDE.md'):
            prefix = 'doc' if rel == 'AGENTS.md' else '.claude'
            text = ''.join(line for line in text.splitlines(keepends=True)
                           if not any(re.match(r'^-\s+`' + re.escape(prefix + '/' + name) + '`', line)
                                      for name in selection['skip_modules']))
        rendered[rel] = text
    return rendered


def all_template_paths():
    paths = set()
    for framework in TEMPLATES:
        paths.update(template_files(framework, DEFAULT_SELECTION, {'module': 'App', 'app': 'app'}))
    return paths


def historical_template_path(rel):
    """Retired assets must still be confined to the published Markdown layouts."""
    return isinstance(rel, str) and bool(re.fullmatch(
        r'(?:\.claude|doc)/(?:agents/)?[A-Za-z0-9_-][A-Za-z0-9_.-]*\.md', rel))


def policy_for(framework):
    common = ['*.sh', '**/*.sh', '*.py', '**/*.py', '.github/workflows/*.yml', '.gitea/workflows/*.yml']
    extensions = {
        'phoenix': ['ex', 'exs', 'heex', 'eex', 'js', 'ts', 'css'],
        'sinatra': ['rb', 'erb', 'js', 'css'], 'rails': ['rb', 'erb', 'js', 'css'], 'zola': ['html', 'css', 'scss', 'js'],
        'escript': ['ex', 'exs'], 'mix': ['ex', 'exs'], 'ruby-cli': ['rb'],
        'bash-cli': [], 'ts-cli': ['ts', 'js', 'mjs'],
    }[framework]
    source = common + [pattern for ext in extensions for pattern in ('*.' + ext, '**/*.' + ext)]
    if framework in ('sinatra', 'rails', 'ruby-cli'):
        source += ['Gemfile', 'Rakefile', '*.gemspec']
    if framework in ('bash-cli', 'ruby-cli'):
        source += ['bin/*', 'exe/*']
    if framework == 'rails':
        source += ['bin/*', 'config.ru', 'Dockerfile', 'config/*.yml', 'config/**/*.yml']
    if framework == 'ts-cli':
        source += ['package.json', 'tsconfig.json']
    tests = ['test/**', 'tests/**', 'spec/**', '**/*_test.py', '**/*_test.exs',
             '**/*_spec.rb', '**/*.test.ts', '**/*.spec.ts', '**/*.test.js']
    if framework == 'rails':
        tests += ['features/**', 'support/coverage.rb', 'script/coverage.rb']
    return {'schema_version': 2, 'source_globs': source, 'test_globs': tests}


def hook_entries(data):
    """Validate hook structure and enumerate individual registrations."""
    hooks = data.get('hooks', {})
    if not isinstance(hooks, dict):
        raise ValueError('Invalid hooks configuration')
    for event, registrations in hooks.items():
        if not isinstance(registrations, list):
            raise ValueError('Invalid hook registrations')
        for reg in registrations:
            if not isinstance(reg, dict) or not isinstance(reg.get('hooks', []), list):
                raise ValueError('Invalid hook registration')
            for hook in reg.get('hooks', []):
                if not isinstance(hook, dict) or not isinstance(hook.get('command', ''), str):
                    raise ValueError('Invalid hook object')
            yield event, reg


def merge_template_hooks(text, old_owned, desired):
    data = object_json(text, '.claude/settings.json')
    list(hook_entries(data))
    hooks = data.setdefault('hooks', {})
    for event, registrations in old_owned.items():
        current = hooks.get(event, [])
        for registration in registrations:
            if registration in current:
                current.remove(registration)
    for event, registration in hook_entries(desired):
        current = hooks.setdefault(event, [])
        if registration not in current:
            current.append(copy.deepcopy(registration))
    return encoded(data)


def owned_projection(rel, text, own_hooks, template_paths):
    if rel in ('AGENTS.md', 'CLAUDE.md') or rel in installer.OPTIONAL_GUIDES and rel not in template_paths:
        return region(text, BEGIN, END) + region(text, installer.BEGIN, installer.END)
    if rel in JSON_CONFIGS:
        data = object_json(text, rel)
        list(hook_entries(data))
        found = {}
        for event, expected in own_hooks.get(rel, {}).items():
            current = list(data.get('hooks', {}).get(event, []))
            found[event] = []
            for registration in expected:
                if registration in current:
                    found[event].append(registration)
                    current.remove(registration)
        return encoded(found)
    if rel == '.codex/config.toml':
        data = tomllib.loads(text)
        if any(not isinstance(data.get(table, {}), dict) for table in ('features', 'agents')):
            raise ValueError('Codex features and agents must be TOML tables')
        return encoded({table: data.get(table, {}).get(key) for table, key in
                        (('features', 'hooks'), ('agents', 'enabled'))})
    if rel == '.gitattributes':
        return installer.AUDIT_ATTRIBUTE if installer.AUDIT_ATTRIBUTE in text.splitlines() else ''
    return text


def names_for(root, framework):
    name = root.name.replace('-', '_')
    module = ''.join(word[:1].upper() + word[1:] for word in name.split('_'))
    if framework == 'zola':
        module = root.name.replace('_', ' ').replace('-', ' ').title()
        name = root.name
    elif framework in ('phoenix', 'escript', 'mix') and (root / 'mix.exs').is_file():
        text = (root / 'mix.exs').read_text()
        app = re.search(r'\bapp:\s*:([a-zA-Z0-9_]+)', text)
        mod = re.search(r'\bdefmodule\s+([A-Za-z0-9_.]+)\.MixProject\b', text)
        if app:
            name = app.group(1)
        if mod:
            module = mod.group(1)
    return {'module': module, 'app': name}


def target_path(raw):
    root = Path(raw).absolute()
    # macOS /tmp itself is an OS alias; callers commonly use it. Resolve only
    # after rejecting target aliases and aliases inside the requested app path.
    for path in (root, *root.parents):
        if path.is_symlink() and str(path) not in ('/tmp', '/var'):
            raise ValueError('Symlink target path: ' + str(path))
    root = root.resolve()
    if root.exists() and not root.is_dir():
        raise ValueError('Target must be a directory')
    return root


def plan(root, args):
    allowed = installer.MANAGED_PATHS | all_template_paths()
    for rel in allowed | {MANIFEST, GUIDANCE}:
        installer.safe_destination(root, rel)
    old_text = read(root, MANIFEST)
    old = object_json(old_text, MANIFEST)
    if old_text:
        if old.get('schema_version') != 1 or not isinstance(old.get('files'), dict):
            raise ValueError('Invalid lifecycle manifest')
        for rel, value in old['files'].items():
            if ((rel not in allowed and not (historical_template_path(rel)
                                             and rel in old.get('template_files', [])))
                    or not isinstance(value, str) or not re.fullmatch('[0-9a-f]{64}', value)):
                raise ValueError('Unknown or invalid manifest path/hash: ' + str(rel))
            installer.safe_destination(root, rel)
        if (not isinstance(old.get('template_files'), list)
                or any(not isinstance(rel, str) or rel not in old['files'] for rel in old['template_files'])):
            raise ValueError('Invalid template ownership manifest')
        if not isinstance(old.get('owned_hooks'), dict) or not isinstance(old.get('template_hooks'), dict):
            raise ValueError('Invalid hook ownership manifest')
        for rel, hooks in old['owned_hooks'].items():
            if rel not in JSON_CONFIGS:
                raise ValueError('Invalid hook ownership path')
            list(hook_entries({'hooks': hooks}))
        list(hook_entries({'hooks': old['template_hooks']}))
    framework = args.framework or old.get('framework')
    if framework is None:
        framework = next((fw for marker, fw in (('mix.exs', 'phoenix'), ('config/application.rb', 'rails'), ('Gemfile', 'sinatra'),
                                                ('config.toml', 'zola'), ('package.json', 'ts-cli'))
                          if (root / marker).is_file()), None)
    if framework not in STACKS:
        raise ValueError('Unknown framework; supply --framework ' + '|'.join(STACKS))
    app_type = args.app_type or STACKS[framework]
    if app_type != STACKS[framework]:
        raise ValueError('App type does not match framework')
    has_options = any((args.skip_module is not None, args.skip_agent is not None,
                       args.hook is not None, args.no_setup, args.all))
    if old and args.command != 'configure' and (has_options or framework != old['framework']):
        raise ValueError('Use configure to change installed framework or selections')
    selection = copy.deepcopy(old.get('selection', DEFAULT_SELECTION))
    if args.all or old and framework != old['framework']:
        selection = copy.deepcopy(DEFAULT_SELECTION)
    if not isinstance(selection, dict) or set(selection) != set(DEFAULT_SELECTION):
        raise ValueError('Invalid recorded selection')
    # A recorded exclusion was validated when installed. If that option is
    # retired upstream, prune only the obsolete saved choice; new explicit
    # choices still pass the strict current-template validation below.
    if old:
        rows = template_rows(framework)
        for argument, field, role in ((args.skip_module, 'skip_modules', 'optional'),
                                      (args.skip_agent, 'skip_agents', 'agent')):
            if argument is None:
                values = selection[field]
                if (not isinstance(values, list) or any(not isinstance(value, str) or
                        not re.fullmatch(r'[A-Za-z0-9_-][A-Za-z0-9_.-]*\.md', value) for value in values)):
                    raise ValueError('Invalid recorded ' + field)
                available = {row[1] for row in rows if row[0] == role}
                selection[field] = [value for value in values if value in available]
    for argument, key in ((args.skip_module, 'skip_modules'), (args.skip_agent, 'skip_agents'), (args.hook, 'hook')):
        if argument is not None:
            selection[key] = sorted(set(argument)) if isinstance(argument, list) else argument
    if args.no_setup:
        selection['no_setup'] = True
    validate_selection(framework, selection)
    names = old.get('names', names_for(root, framework))
    if not isinstance(names, dict) or set(names) != {'module', 'app'} or any(not isinstance(v, str) for v in names.values()):
        raise ValueError('Invalid recorded app names')
    names = {**names}
    if args.module_name is not None:
        names['module'] = args.module_name
    if args.app_name is not None:
        names['app'] = args.app_name
    drift = []
    for rel, expected in old.get('files', {}).items():
        if (not (root / rel).exists() or digest(owned_projection(
                rel, read(root, rel), old['owned_hooks'], old['template_files'])) != expected):
            drift.append(rel)
    template = template_files(framework, selection, names)
    template_paths = sorted(template)
    desired_hooks = object_json(template.pop('.claude/settings.json', ''), 'template settings')
    overlays = dict(template)
    # Optional legacy guides are normally preserved. A guide that was generated
    # as a template asset instead belongs to the lifecycle and can be retired.
    for rel in old.get('template_files', []):
        if rel in installer.OPTIONAL_GUIDES and rel not in template_paths:
            overlays[rel] = ''
    for guide in ('AGENTS.md', 'CLAUDE.md'):
        content = ('Read [.docs/project-guidance.md](.docs/project-guidance.md) for app-specific rules.\n'
                   'Keep local guidance there; maintain shared content with agent-docs.sh.\n\n' + template.pop(guide))
        overlays[guide] = section(read(root, guide), content)
    overlays['.claude/settings.json'] = merge_template_hooks(
        read(root, '.claude/settings.json'), old.get('template_hooks', {}), desired_hooks)
    metadata = workflow.release_metadata()
    provenance = {key: metadata[key] for key in ('version', 'source_commit')}
    workflow_plan = installer.render(root, policy_for(framework), existing_files=overlays, installer_metadata=provenance)
    if not old and workflow_plan['report']['previous_drift']:
        drift.extend(workflow_plan['report']['previous_drift'])
    files = {**template, **workflow_plan['files']}
    # Only exact generated registrations are owned. User registrations are
    # retained, and changing an owned registration makes the old projection drift.
    empty = {rel: '' for rel in installer.MANAGED_PATHS}
    empty[installer.MANIFEST_PATH] = '{"sha256": {}}'
    fresh = installer.render(root, policy_for(framework), existing_files=empty, installer_metadata=provenance)
    owned_hooks = {}
    for rel in JSON_CONFIGS:
        owned_hooks[rel] = object_json(fresh['files'][rel], rel)['hooks']
    for event, registration in hook_entries(desired_hooks):
        owned_hooks['.claude/settings.json'].setdefault(event, []).append(registration)
    hashes = {}
    for rel, text in list(files.items()):
        if rel == installer.MANIFEST_PATH:
            continue
        projection = owned_projection(rel, text, owned_hooks, template_paths)
        hashes[rel] = digest(projection)
        current = read(root, rel)
        prior_hooks = old.get('owned_hooks', {})
        prior_templates = old.get('template_files', [])
        if ((root / rel).exists() and owned_projection(rel, current, owned_hooks, template_paths) == projection
                and owned_projection(rel, current, prior_hooks, prior_templates)
                == owned_projection(rel, text, prior_hooks, prior_templates)):
            files[rel] = current
    # The workflow-only manifest hashes whole files. Lifecycle ownership is
    # selective; do not rewrite that compatibility snapshot for app-owned edits.
    old_hashes = {key: value for key, value in old.get('files', {}).items() if key != installer.MANIFEST_PATH}
    if old and hashes == old_hashes and provenance == old.get('installer'):
        files[installer.MANIFEST_PATH] = read(root, installer.MANIFEST_PATH)
    hashes[installer.MANIFEST_PATH] = digest(files[installer.MANIFEST_PATH])
    manifest = {'schema_version': 1, 'framework': framework, 'app_type': app_type,
                'selection': selection, 'names': names, 'installer': provenance,
                'files': hashes, 'template_files': template_paths, 'owned_hooks': owned_hooks,
                'template_hooks': desired_hooks.get('hooks', {})}
    files[MANIFEST] = encoded(manifest)
    if not (root / GUIDANCE).exists():
        files[GUIDANCE] = ('# Project guidance\n\nAdd app-specific rules here. This file belongs to your app and is preserved by\n'
                           'agent-docs.sh updates. Shared framework guidance lives in AGENTS.md and CLAUDE.md;\n'
                           'the agent workflow is documented in [agent-workflow.md](agent-workflow.md).\n')
    removed = sorted(set(old.get('files', {})) - set(files))
    changed = sorted(rel for rel, text in files.items() if not (root / rel).exists() or read(root, rel) != text)
    for rel in set(files) | set(removed):
        installer.safe_destination(root, rel)
    status = 'drift' if drift else 'missing' if not old else 'update' if changed or removed else 'current'
    return {'status': status, 'native_activation': 'UNKNOWN', 'changed_files': changed,
            'removed_files': removed, 'drift_files': sorted(set(drift))}, files


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('check', 'diff', 'update', 'configure'))
    parser.add_argument('target', help='Explicit application directory')
    parser.add_argument('--framework')
    parser.add_argument('--app-type')
    parser.add_argument('--skip-module', action='append')
    parser.add_argument('--skip-agent', action='append')
    parser.add_argument('--hook')
    parser.add_argument('--no-setup', action='store_true')
    parser.add_argument('--all', action='store_true', help='Reset configure selections to defaults')
    parser.add_argument('--json', action='store_true')
    parser.add_argument('--module-name', help=argparse.SUPPRESS)
    parser.add_argument('--app-name', help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    result = {'status': 'error', 'native_activation': 'UNKNOWN'}
    files = {}
    try:
        root = target_path(args.target)
        result, files = plan(root, args)
        mutating = args.command in ('update', 'configure')
        if mutating and result['drift_files']:
            result['error'] = 'Managed drift blocks update; use diff and reconcile local changes first.'
            code = 2
        elif mutating:
            for rel in result['removed_files']:
                installer.safe_destination(root, rel).unlink()
            for rel in result['changed_files']:
                path = installer.safe_destination(root, rel)
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(files[rel])
                if path.name == 'cloud-setup.sh':
                    path.chmod(0o755)
            result['status'] = 'current'
            code = 0
        else:
            code = int(result['status'] != 'current')
        if args.command == 'diff' and not args.json:
            for rel in result['changed_files'] + result['removed_files']:
                print(''.join(difflib.unified_diff(read(root, rel).splitlines(keepends=True),
                    files.get(rel, '').splitlines(keepends=True), fromfile=str(root / rel),
                    tofile=str(root / rel))), end='')
    except (ValueError, OSError, TypeError, KeyError) as error:
        result = {'status': 'error', 'native_activation': 'UNKNOWN', 'error': str(error)}
        code = 2
    if args.json:
        print(encoded(result), end='')
    else:
        print('agent-docs: ' + result['status'] + ' (native activation UNKNOWN)')
        if result.get('error'):
            print(result['error'])
        if result.get('drift_files'):
            print('Drift: ' + ', '.join(result['drift_files']))
        print('Native trust and hook invocation require separate host validation.')
    return code


if __name__ == '__main__':
    sys.exit(main())
