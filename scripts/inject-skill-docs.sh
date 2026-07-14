#!/usr/bin/env bash
#
# inject-skill-docs.sh — drop the Claude skill docs into a Phoenix app and add
# the deps the docs assume. Absorbed from generic-phoenix-claude's
# new_phx_app.sh; the template lives in this repo at app-template/.
#
#   ./scripts/inject-skill-docs.sh <app_dir>
#
# What it does:
#   1. Injects deps the docs assume (default req + oban + cucumberex; override
#      with APP_EXTRA_DEPS, '|'-separated mix.exs entries, empty string = none).
#      Deps already declared in mix.exs are skipped.
#   2. Copies app-template/CLAUDE.md -> <app_dir>/CLAUDE.md and
#      app-template/.claude/*.md -> <app_dir>/.claude/, rewriting the MyApp /
#      my_app placeholders to the app's real module/app names (compounds like
#      MyAppWeb and :my_app are covered by plain global replace).
#   3. Copies the Claude Code cloud-environment bootstrap
#      (.claude/cloud-setup.sh + the .claude/settings.json SessionStart hook
#      that runs it), same placeholder rewrite applied to the script.
#
# Idempotent-ish: re-running overwrites the docs (template wins) and skips
# already-present deps. Existing files the app owns are never touched.
#
# Portable: BSD/macOS bash, grep, sed, perl.
set -euo pipefail

fail() { printf 'inject-skill-docs: %s\n' "$*" >&2; exit 1; }
log()  { printf '\033[32m==>\033[0m %s\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="$SCRIPT_DIR/../app-template"

APP_DIR="${1:-}"
[ -n "$APP_DIR" ] || fail "usage: inject-skill-docs.sh <app_dir>"
[ -f "$APP_DIR/mix.exs" ] || fail "no mix.exs in $APP_DIR"
[ -f "$TEMPLATE_DIR/CLAUDE.md" ] || fail "no CLAUDE.md in $TEMPLATE_DIR"
[ -d "$TEMPLATE_DIR/.claude" ]   || fail "no .claude/ in $TEMPLATE_DIR"

# shellcheck source=app-meta.sh
. "$SCRIPT_DIR/app-meta.sh"
APP_NAME="$(app_name "$APP_DIR")"
APP_MODULE="$(app_module "$APP_DIR")"

# ---- 1. deps the docs assume ---------------------------------------------------
# '|'-separated mix.exs entries; APP_EXTRA_DEPS="" opts out entirely.
default_deps='{:req, "~> 0.5"}|{:oban, "~> 2.19"}|{:cucumberex, "~> 0.2", only: [:dev, :test], runtime: false}'
APP_EXTRA_DEPS="${APP_EXTRA_DEPS-$default_deps}"

inject_deps() {
  local mixfile="$APP_DIR/mix.exs" lines="" dep atom
  [ -n "$APP_EXTRA_DEPS" ] || { log "skill docs: no extra deps requested"; return 0; }

  local IFS='|'
  for dep in $APP_EXTRA_DEPS; do
    dep="${dep#"${dep%%[![:space:]]*}"}"; dep="${dep%"${dep##*[![:space:]]}"}"
    dep="${dep%,}"
    [ -z "$dep" ] && continue
    atom="${dep#\{}"; atom="${atom%%,*}"
    atom="${atom#"${atom%%[![:space:]]*}"}"
    if [ -n "$atom" ] && grep -q "{${atom}," "$mixfile"; then
      log "skill docs: dep ${atom} already in mix.exs — skipping"
      continue
    fi
    lines="${lines}      ${dep},"$'\n'
  done
  [ -z "$lines" ] && { log "skill docs: all extra deps already present"; return 0; }

  # Insert right after the `{:phoenix,` dep line (present exactly once).
  DEP_BLOCK="$lines" perl -0777 -pi -e '
    my $b = $ENV{DEP_BLOCK};
    s/(\{:phoenix,[^\n]*\n)/$1 . "      # added by inject-skill-docs.sh (see CLAUDE.md)\n" . $b/e;
  ' "$mixfile"
  log "skill docs: injected deps into mix.exs"
}
inject_deps

# ---- 2. copy + rewrite the docs --------------------------------------------------
mkdir -p "$APP_DIR/.claude"
cp "$TEMPLATE_DIR/CLAUDE.md" "$APP_DIR/CLAUDE.md"
count=0
for src in "$TEMPLATE_DIR"/.claude/*.md; do
  [ -e "$src" ] || continue
  cp "$src" "$APP_DIR/.claude/$(basename "$src")"
  count=$((count + 1))
done

# ---- 3. cloud-environment bootstrap (SessionStart hook + setup script) ----------
cp "$TEMPLATE_DIR/.claude/cloud-setup.sh" "$APP_DIR/.claude/cloud-setup.sh"
chmod +x "$APP_DIR/.claude/cloud-setup.sh"
cp "$TEMPLATE_DIR/.claude/settings.json" "$APP_DIR/.claude/settings.json"

find "$APP_DIR/CLAUDE.md" "$APP_DIR/.claude" \
  \( -name '*.md' -o -name 'cloud-setup.sh' \) -type f -print0 \
  | MODULE="$APP_MODULE" APP="$APP_NAME" xargs -0 perl -pi -e \
      's/\QMyApp\E/$ENV{MODULE}/g; s/\Qmy_app\E/$ENV{APP}/g;'

log "skill docs: placed CLAUDE.md + $count docs + cloud setup hook, names rewritten to $APP_MODULE/$APP_NAME"
