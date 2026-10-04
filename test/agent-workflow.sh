#!/usr/bin/env bash
# Active workflow contracts only; archive_v1 remains historical evidence.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PYTHONDONTWRITEBYTECODE=1 python3 -B -m unittest discover -s "$ROOT/test/agent-workflow" -p 'test_*.py' -v
