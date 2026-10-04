#!/usr/bin/env bash
# Offline public lifecycle contracts. Never discover archived legacy tests.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PYTHONDONTWRITEBYTECODE=1 python3 -B -m unittest discover -s "$ROOT/test/agent-docs" -p 'test_*.py' -v
