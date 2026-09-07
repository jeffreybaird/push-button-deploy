#!/usr/bin/env bash
# Legacy Phoenix installer: install selected agent files, then add guide dependencies.
# For files-only retrofit use install-agent-files.sh instead.
# Usage: inject-skill-docs.sh [--agents claude|codex|both] [--force] <app_dir>
# APP_EXTRA_DEPS controls declarations; an empty value disables injection.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/agent-files-common.sh"
agent_options "$@"
[ -z "$AGENT_FRAMEWORK" ] || [ "$AGENT_FRAMEWORK" = phoenix ] || agent_fail 'expected Phoenix framework'
[ -f "$AGENT_DIR/mix.exs" ] || agent_fail "no mix.exs in $AGENT_DIR"
# The installer validates all outputs and handles selection before dependency changes.
"$SCRIPT_DIR/install-agent-files.sh" --framework phoenix "$@"
perl "$SCRIPT_DIR/agent-deps.pl" inject "$AGENT_DIR/mix.exs"
