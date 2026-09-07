#!/usr/bin/env bash
#
# test/claude-docs-smoke.sh — offline smoke test for the Claude-docs injector.
#
# The repo has no other automated test harness; this is the safety net for
# scripts/claude-docs.sh and the three scaffolds that now delegate to it. It
# runs the injector non-interactively into temp dirs and asserts the copy,
# placeholder rewrite, optional-module prune, agent selection and hook variant
# all behave. No network, no mix/bundle/zola — just bash, awk and perl.
#
#   ./test/claude-docs-smoke.sh      # exits non-zero if any assertion fails
#
# App dir names are chosen NOT to coincide with a template's placeholder tokens
# (my_app / MyApp / My Site / my_site), so a leftover placeholder is always
# distinguishable from a correctly-rewritten value.
#
# Portable: BSD/macOS bash.
set -uo pipefail   # NOT -e: we count failures and report them all

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The lib needs a fail()/log() from its caller — invoked indirectly, from it.
# shellcheck disable=SC2317
fail() { printf '\033[31msmoke: %s\033[0m\n' "$*" >&2; exit 1; }
# shellcheck disable=SC2317
log()  { :; }   # quiet — the injector's per-run summary is noise here
# shellcheck source=../scripts/claude-docs.sh
. "$ROOT/scripts/claude-docs.sh"

FAILS=0
section() { printf '\n%s\n' "$1"; }
ok()  { printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAILS=$((FAILS + 1)); }
have_file() { [ -f "$2" ] && ok "$1" || bad "$1 — expected file $2"; }
no_file()   { [ ! -e "$2" ] && ok "$1" || bad "$1 — unexpected $2"; }
no_dir()    { [ ! -d "$2" ] && ok "$1" || bad "$1 — unexpected dir $2"; }
greps()     { grep -q "$3" "$2" 2>/dev/null && ok "$1" || bad "$1 — /$3/ not in $2"; }
no_greps()  { grep -q "$3" "$2" 2>/dev/null && bad "$1 — /$3/ still in $2" || ok "$1"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

inject() { # $1 framework, $2 app_dir  (CD_SKIP_*/CD_HOOK read from the subshell env)
  local vals; vals="$(cd_values_for "$1" "$2")"
  cd_inject "$(cd_template_dir "$1")" "$2" "${vals%%|*}" "${vals#*|}" >/dev/null
}

# ---- phoenix: skip an optional module ------------------------------------------
section "phoenix — dir 'cool_thing' (skip rbac.md)"
d="$WORK/cool_thing"; mkdir -p "$d"
# shellcheck disable=SC2034  # CD_SKIP_MODULES is read by cd_inject inside the subshell
( CD_SKIP_MODULES="rbac.md"; inject phoenix "$d" )
have_file "CLAUDE.md written"                    "$d/CLAUDE.md"
have_file "core module kept"                     "$d/.claude/testing.md"
have_file "optional module kept"                 "$d/.claude/multi-tenancy.md"
no_file   "skipped optional module absent"       "$d/.claude/rbac.md"
no_greps  "skipped module's index bullet gone"   "$d/CLAUDE.md" '^-.*\.claude/rbac\.md'
greps     "kept module's index bullet present"   "$d/CLAUDE.md" '\.claude/multi-tenancy\.md'
have_file "agent test-writer copied"             "$d/.claude/agents/test-writer.md"
have_file "agent code-reviewer copied"           "$d/.claude/agents/code-reviewer.md"
have_file "cloud-setup hook copied"              "$d/.claude/cloud-setup.sh"
have_file "settings.json copied"                 "$d/.claude/settings.json"
no_file   "hook variant not left as a stray"     "$d/.claude/settings.format-hook.json"
no_greps  "no MyApp placeholder left in CLAUDE"  "$d/CLAUDE.md" 'MyApp'
no_greps  "no my_app placeholder left in CLAUDE" "$d/CLAUDE.md" 'my_app'
greps     "module rewritten (CoolThing)"         "$d/CLAUDE.md" 'CoolThing'
greps     "app name rewritten in cloud-setup"    "$d/.claude/cloud-setup.sh" 'cool_thing-cloud-setup'
greps     "agent placeholder rewritten"          "$d/.claude/agents/code-reviewer.md" 'CoolThing'
no_greps  "agent has no leftover MyApp"          "$d/.claude/agents/test-writer.md" 'MyApp'

# ---- sinatra: format hook + skip an agent --------------------------------------
section "sinatra — dir 'shop_api' (format hook, skip test-writer agent)"
d="$WORK/shop_api"; mkdir -p "$d"
# shellcheck disable=SC2034  # CD_HOOK / CD_SKIP_AGENTS are read by cd_inject inside the subshell
( CD_HOOK="format"; CD_SKIP_AGENTS="test-writer.md"; inject sinatra "$d" )
have_file "CLAUDE.md written"                    "$d/CLAUDE.md"
have_file "ruby-only module database.md kept"    "$d/.claude/database.md"
no_file   "skipped agent absent"                 "$d/.claude/agents/test-writer.md"
have_file "kept agent present"                   "$d/.claude/agents/code-reviewer.md"
greps     "format hook wired (PostToolUse)"      "$d/.claude/settings.json" 'PostToolUse'
greps     "format hook runs rubocop"             "$d/.claude/settings.json" 'rubocop'
no_greps  "no MyApp placeholder left"            "$d/CLAUDE.md" 'MyApp'
no_greps  "no my_app placeholder left"           "$d/CLAUDE.md" 'my_app'
greps     "module rewritten (ShopApi)"           "$d/CLAUDE.md" 'ShopApi'

# ---- zola: minimal, no hook, no agents -----------------------------------------
section "zola — dir 'travel_notes' (three core docs, no hook)"
d="$WORK/travel_notes"; mkdir -p "$d"
( inject zola "$d" )
have_file "CLAUDE.md written"                    "$d/CLAUDE.md"
have_file "content.md copied"                    "$d/.claude/content.md"
have_file "templates.md copied"                  "$d/.claude/templates.md"
have_file "deployment.md copied"                 "$d/.claude/deployment.md"
no_file   "no settings.json"                     "$d/.claude/settings.json"
no_dir    "no agents dir"                        "$d/.claude/agents"
no_greps  "no 'My Site' placeholder left"        "$d/CLAUDE.md" 'My Site'
no_greps  "no 'my_site' placeholder left"        "$d/CLAUDE.md" 'my_site'
greps     "title rewritten (Travel Notes)"       "$d/CLAUDE.md" 'Travel Notes'

# ---- default (skip nothing) reproduces the full set ----------------------------
section "phoenix — dir 'full_app' (default: include everything)"
d="$WORK/full_app"; mkdir -p "$d"
( inject phoenix "$d" )
have_file "optional rbac.md present by default"  "$d/.claude/rbac.md"
have_file "optional payment present by default"  "$d/.claude/payment-integration.md"
have_file "both agents present by default"       "$d/.claude/agents/test-writer.md"

# ---- bash -n over the scripts this feature touches -----------------------------
section "syntax (bash -n)"
for f in scripts/prompt.sh scripts/claude-docs.sh scripts/inject-skill-docs.sh \
         scripts/new-sinatra-app.sh scripts/new-zola-site.sh claude-docs.sh bootstrap.sh; do
  if bash -n "$ROOT/$f" 2>/dev/null; then ok "bash -n $f"; else bad "bash -n $f"; fi
done

# ---- verdict -------------------------------------------------------------------
printf '\n'
if [ "$FAILS" -eq 0 ]; then
  printf '\033[32mall smoke checks passed\033[0m\n'; exit 0
else
  printf '\033[31m%s smoke check(s) failed\033[0m\n' "$FAILS"; exit 1
fi
