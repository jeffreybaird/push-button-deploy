#!/usr/bin/env python3
"""Inspect React metadata without installing packages or executing app code."""
import json
import sys
from pathlib import Path


def validate(root, identify=False):
    package = json.loads((root / 'package.json').read_text())
    dependencies = {**package.get('dependencies', {}), **package.get('devDependencies', {})}
    if not all(dependencies.get(name) for name in ('react', 'react-dom')):
        raise ValueError('package.json must declare react and react-dom')
    if identify:
        return
    if not dependencies.get('vite'):
        raise ValueError('React deployment supports Vite static applications')
    scripts = package.get('scripts', {})
    if not all(isinstance(scripts.get(key), str) and scripts[key].strip() for key in ('dev', 'test', 'build')):
        raise ValueError('package.json requires dev, test and build scripts')
    for name in ('index.html', '.node-version'):
        if not (root / name).is_file() or not (root / name).read_text().strip():
            raise ValueError(f'missing {name}')
    lock = json.loads((root / 'package-lock.json').read_text())
    if lock.get('lockfileVersion', 0) < 2:
        raise ValueError('package-lock.json must use lockfileVersion 2 or newer')
    packages = lock.get('packages', {})
    locked = packages.get('')
    if not isinstance(locked, dict):
        raise ValueError('package-lock.json is missing root package metadata')
    for key in ('dependencies', 'devDependencies', 'optionalDependencies'):
        if locked.get(key, {}) != package.get(key, {}):
            raise ValueError(f'package-lock.json {key} disagree with package.json; run npm install')
    for name in ('react', 'react-dom', 'vite'):
        if not packages.get('node_modules/' + name):
            raise ValueError(f'package-lock.json is missing {name}')


if __name__ == '__main__':
    try:
        identify = len(sys.argv) == 3 and sys.argv[1] == '--identify'
        validate(Path(sys.argv[-1]), identify)
    except (OSError, ValueError, TypeError, AttributeError) as error:
        print(f'React application: {error}', file=sys.stderr)
        sys.exit(1)
