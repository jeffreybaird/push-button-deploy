#!/usr/bin/env bash
#
# claude-docs.sh — guided creation of an app's Claude Code docs.
#
# Walks you through which pieces of CLAUDE.md + .claude/ (guidance modules,
# starter agents, the SessionStart cloud-setup hook) your app needs, assembles
# them from this repo's static templates with the app's name filled in, and
# offers to open the result in your editor. Runs on a freshly generated app or
# to retrofit an existing repo — it only writes CLAUDE.md and .claude/, never
# your code.
#
#   ./claude-docs.sh                     guided, framework inferred from the cwd
#   ./claude-docs.sh ~/src/myapp         guided, into that directory
#   ./claude-docs.sh --framework sinatra ~/src/myapp
#   ./claude-docs.sh --all ~/src/myapp   non-interactive: include everything
#
# The heavy lifting (copy, placeholder rewrite, index prune) lives in
# scripts/claude-docs.sh, shared with bootstrap.sh and the framework scaffolds,
# so a guided run and an automatic bootstrap run place docs identically.
#
# Portable: BSD/macOS bash, awk, perl.
set -euo pipefail

fail() { printf '\033[31mclaude-docs: %s\033[0m\n' "$*" >&2; exit 1; }
log()  { printf '\033[32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m==> WARN\033[0m %s\n' "$*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/claude-docs.sh
. "$SCRIPT_DIR/scripts/claude-docs.sh"   # also sources scripts/prompt.sh

usage() {
  cat <<EOF
claude-docs.sh — guided creation of an app's Claude Code docs (CLAUDE.md + .claude/).

  ./claude-docs.sh [options] [app_dir]      app_dir defaults to .

Options:
  --framework, -f <name>   phoenix, sinatra or zola. Inferred from the app's
                           marker file (mix.exs / Gemfile / config.toml) when
                           omitted; you are prompted if it can't be inferred
  --all                    include everything without prompting (needs no TTY)
  --help, -h               this message

What it writes, tailored by your answers:
  CLAUDE.md                the top-level project guide
  .claude/*.md             guidance modules (core always; optional ones you pick)
  .claude/agents/*.md      starter subagents (test-writer, code-reviewer)
  .claude/settings.json    a SessionStart hook that prepares cloud sessions
                           (dynamic frameworks only; optional 'format' variant)

Frameworks with a template today: $(cd_frameworks).
EOF
}

# ---- args ----------------------------------------------------------------------
# FRAMEWORK may arrive from the environment (e.g. when bootstrap.sh --docs
# forwards it); --framework overrides it.
FRAMEWORK="${FRAMEWORK:-}"
APP_DIR=""
INCLUDE_ALL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --framework|-f) FRAMEWORK="${2:-}"; shift 2 ;;
    --framework=*)  FRAMEWORK="${1#*=}"; shift ;;
    -f=*)           FRAMEWORK="${1#*=}"; shift ;;
    --all)          INCLUDE_ALL=1; shift ;;
    --help|-h)      usage; exit 0 ;;
    -*)             fail "unknown option '$1' (see --help)" ;;
    *)              [ -z "$APP_DIR" ] || fail "more than one app_dir given: '$APP_DIR' and '$1'"; APP_DIR="$1"; shift ;;
  esac
done
APP_DIR="${APP_DIR:-.}"

abs_dir() { # best-effort absolute path (dir may not exist yet)
  if [ -d "$1" ]; then (cd "$1" && pwd); else printf '%s\n' "$1"; fi
}

have_tty() { [ -r /dev/tty ]; }

# ---- framework -----------------------------------------------------------------
if [ -z "$FRAMEWORK" ]; then
  FRAMEWORK="$(cd_infer_framework "$APP_DIR")"
  [ -n "$FRAMEWORK" ] && log "detected framework: $FRAMEWORK (from $APP_DIR)"
fi
if [ -z "$FRAMEWORK" ]; then
  { [ "$INCLUDE_ALL" -eq 1 ] || ! have_tty; } \
    && fail "could not infer the framework from $APP_DIR — pass --framework <$(cd_frameworks | tr ' ' '|')>"
  ask_menu "Which framework are these docs for?" phoenix \
    < <(for f in $(cd_frameworks); do printf '%s|%s\n' "$f" "$(basename "$(cd_template_dir "$f")")"; done)
  FRAMEWORK="$REPLY_VALUE"
fi

TEMPLATE_DIR="$(cd_template_dir "$FRAMEWORK")"
if [ -z "$TEMPLATE_DIR" ] || [ ! -d "$TEMPLATE_DIR" ]; then
  fail "no template for framework '$FRAMEWORK'. Known: $(cd_frameworks)"
fi

# ---- selection -----------------------------------------------------------------
# Defaults (skip nothing) = include everything, which is what --all keeps.
CD_SKIP_MODULES=""; CD_SKIP_AGENTS=""; CD_HOOK=""; CD_NO_SETUP=""
if [ "$INCLUDE_ALL" -eq 0 ]; then
  have_tty || fail "guided mode needs a terminal — pass --all to include everything, or run in a terminal"
  log "guided setup — Enter accepts the default (include) at each step"
  cd_prompt_selection "$TEMPLATE_DIR"
fi

# ---- values + recap ------------------------------------------------------------
vals="$(cd_values_for "$FRAMEWORK" "$APP_DIR")"
MODVAL="${vals%%|*}"; APPVAL="${vals#*|}"

printf '\n' >&2
log "about to write Claude docs:"
printf '    framework    %s\n' "$FRAMEWORK" >&2
printf '    directory    %s\n' "$(abs_dir "$APP_DIR")" >&2
printf '    names        %s / %s\n' "$MODVAL" "$APPVAL" >&2
[ -n "$CD_SKIP_MODULES" ] && printf '    skip modules %s\n' "$(printf '%s' "$CD_SKIP_MODULES" | sed 's/^ //')" >&2
[ -n "$CD_SKIP_AGENTS" ]  && printf '    skip agents  %s\n' "$(printf '%s' "$CD_SKIP_AGENTS" | sed 's/^ //')" >&2
[ -n "$CD_HOOK" ]         && printf '    extra hook   %s\n' "$CD_HOOK" >&2
[ -n "$CD_NO_SETUP" ]     && printf '    cloud hook   omitted\n' >&2
printf '\n' >&2

if have_tty && [ "$INCLUDE_ALL" -eq 0 ]; then
  ask_yesno "Proceed?" y
  [ "$REPLY_VALUE" = true ] || fail "cancelled"
fi

# ---- inject --------------------------------------------------------------------
cd_inject "$TEMPLATE_DIR" "$APP_DIR" "$MODVAL" "$APPVAL"

# ---- open in editor ------------------------------------------------------------
if have_tty && [ "$INCLUDE_ALL" -eq 0 ]; then
  ed="${VISUAL:-${EDITOR:-}}"
  ask_yesno "open CLAUDE.md in your editor${ed:+ ($ed)}?" n
  if [ "$REPLY_VALUE" = true ]; then
    "${ed:-vi}" "$APP_DIR/CLAUDE.md" < /dev/tty > /dev/tty 2>&1 || warn "editor exited non-zero"
  fi
fi

log "done. Review $APP_DIR/CLAUDE.md and $APP_DIR/.claude/ and adapt them to your app."
