#!/usr/bin/env bash
# Exercise the real interactive function with prompt boundaries doubled.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
log() { :; }
warn() { :; }
fail() { printf '%s\n' "$*" >&2; exit 1; }
. "$ROOT/scripts/app-types.sh"
. "$ROOT/scripts/provider.sh"
. "$ROOT/scripts/bootstrap/config.sh"
# Loading just the function avoids bootstrap's main/cloud side effects.
awk '/^interactive\(\) \{/{copy=1} copy{print} copy && /^}$/{exit}' "$ROOT/bootstrap.sh" > "$WORK/interactive.sh"
. "$WORK/interactive.sh"
abs_dir() { printf '%s' "$1"; }
cd_template_dir() { :; }
ask_yesno() { REPLY_VALUE=true; [ "$1" != 'Proceed?' ] || printf true; }
ask_text() { REPLY_VALUE="$2"; }
ask_menu() {
  local options
  options="$(cat)"
  case "$1" in
    'What are you building?') REPLY_VALUE=service ;;
    'Which language?')
      [ "$(printf '%s\n' "$options" | cut -d'|' -f1 | grep -c '^typescript$')" = 1 ] || fail 'TypeScript must appear once in language menu'
      REPLY_VALUE=typescript ;;
    *framework*|*Framework*)
      printf '%s\n' "$options" | grep -q '^react|' || fail 'React missing from framework menu'
      REPLY_VALUE="$SELECT_FRAMEWORK" ;;
    'Where do the repo and CI live?') REPLY_VALUE=github ;;
    'Database backend?') fail 'Front-end-only React must not offer PostgreSQL' ;;
    *) fail "unexpected menu: $1" ;;
  esac
}
for SELECT_FRAMEWORK in react; do
  unset APP_TYPE FRAMEWORK LANGUAGE DATABASE_BACKEND ENABLE_STAGING
  APP_TYPE_FLAG=""; LANGUAGE_FLAG=""
  interactive "$WORK/app"
  resolve_app_config
  [ "$FRAMEWORK" = "$SELECT_FRAMEWORK" ]
  [ "$LANGUAGE/$DATABASE_BACKEND" = typescript/none ]
  if wants_staging; then fail 'React cannot enable PR server staging'; fi
done
echo 'React interactive selection checks passed'
