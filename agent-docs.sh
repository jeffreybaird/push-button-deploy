#!/usr/bin/env bash
# Public lifecycle entry point. The bundle can be read-only and outside Git.
set -euo pipefail
_ad_self="${BASH_SOURCE[0]}"
while [ -L "$_ad_self" ]; do
  _ad_dir="$(cd -P "$(dirname "$_ad_self")" && pwd)"
  _ad_self="$(readlink "$_ad_self")"
  case "$_ad_self" in /*) ;; *) _ad_self="$_ad_dir/$_ad_self" ;; esac
done
_ad_root="${PBD_ROOT:-$(cd -P "$(dirname "$_ad_self")" && pwd)}"
command -v python3 >/dev/null || { printf 'agent-docs: Python 3.11+ is required\n' >&2; exit 2; }
python3 -B -c 'import sys; sys.exit(sys.version_info < (3, 11))' || {
  printf 'agent-docs: Python 3.11+ is required\n' >&2; exit 2;
}
exec python3 -B "$_ad_root/scripts/agent-workflow/lifecycle.py" "$@"
