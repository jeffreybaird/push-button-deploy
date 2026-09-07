#!/usr/bin/env bash
# Shared argument parsing and selection. Source from an installer/scaffolder.
agent_fail() { printf 'agent files: %s\n' "$*" >&2; exit 1; }
agent_options() {
  AGENT_FRAMEWORK=""; AGENT_FORCE=0; AGENT_DIR=""
  AGENT_SELECTION="${APP_AGENTS-}"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --agents|--framework)
        [ "$#" -ge 2 ] || agent_fail "$1 requires a value"
        case "$1" in --agents) AGENT_SELECTION="$2";; --framework) AGENT_FRAMEWORK="$2";; esac
        shift 2 ;;
      --force) AGENT_FORCE=1; shift ;;
      --help|-h)
        printf 'Usage: %s [--agents claude|codex|both] [--framework phoenix|sinatra|zola] [--force] <app_dir>\n' "$(basename "$0")"
        exit 0 ;;
      --) shift; [ "$#" -eq 1 ] || agent_fail 'expected one app directory'; AGENT_DIR="$1"; shift ;;
      -*) agent_fail "unknown option: $1" ;;
      *) [ -z "$AGENT_DIR" ] || agent_fail 'expected one app directory'; AGENT_DIR="$1"; shift ;;
    esac
  done
  [ -n "$AGENT_DIR" ] || agent_fail 'app directory required (use --help)'
  case "$AGENT_FRAMEWORK" in ''|phoenix|sinatra|zola) ;; *) agent_fail "invalid framework: $AGENT_FRAMEWORK";; esac
  case "$AGENT_SELECTION" in ''|claude|codex|both) ;; *) agent_fail "invalid APP_AGENTS/--agents: $AGENT_SELECTION";; esac
}
agent_select() {
  if [ -z "$AGENT_SELECTION" ]; then
    if [ -t 0 ]; then
      while :; do
        printf 'Agent files: 1) Claude  2) OpenAI Codex  3) Both [1]: ' >&2
        IFS= read -r AGENT_SELECTION || agent_fail 'selection cancelled'
        case "$AGENT_SELECTION" in
          ''|1|claude) AGENT_SELECTION=claude; break ;;
          2|codex) AGENT_SELECTION=codex; break ;;
          3|both) AGENT_SELECTION=both; break ;;
          *) printf 'Choose Claude, Codex, or both.\n' >&2 ;;
        esac
      done
    else
      AGENT_SELECTION=claude
    fi
  fi
  export APP_AGENTS="$AGENT_SELECTION"
}
