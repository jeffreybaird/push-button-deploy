# scripts/claude-docs.sh — the one Claude-docs injector.
#
# Copies a template root's CLAUDE.md + .claude/ (guidance modules, agents, a
# SessionStart cloud-setup hook) into an app, rewriting name placeholders. It is
# the single implementation behind:
#   - bootstrap.sh's automatic injection for a freshly generated app,
#   - scripts/inject-skill-docs.sh / new-sinatra-app.sh / new-zola-site.sh,
#   - the top-level ./claude-docs.sh guided command.
#
# TEMPLATE ROOTS carry a `claude-docs.manifest` (see app-template/…) declaring
# the placeholder pair, which modules are optional, which agents ship, and any
# hook variant. Core = every .claude/*.md not marked optional. No manifest =>
# include everything, prompt for nothing.
#
# SELECTION is expressed as SKIP lists so the default (skip nothing) reproduces
# the historical "copy it all" behavior exactly — the callers that don't want a
# guided run get byte-identical output plus whatever the template now ships:
#   CD_SKIP_MODULES  space-separated optional-module basenames to leave out
#   CD_SKIP_AGENTS   space-separated agent basenames to leave out
#   CD_HOOK          "" = plain settings.json; "format" = settings.format-hook.json
#   CD_NO_SETUP      non-empty = omit settings.json + cloud-setup.sh entirely
#
# Sourced as a lib. Requires the caller's fail()/log() (falls back to its own if
# absent). Prompt helpers are loaded only by the guided flow.
#
# Portable: BSD/macOS bash, awk, perl.

CD_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CD_ROOT="$(cd "$CD_LIB_DIR/.." && pwd)"

declare -F fail >/dev/null 2>&1 || fail() { printf 'claude-docs: %s\n' "$*" >&2; exit 1; }
declare -F log  >/dev/null 2>&1 || log()  { printf '\033[32m==>\033[0m %s\n' "$*"; }

# Public facade. Callers keep the cd_* API and CD_* selection options.
. "$CD_LIB_DIR/claude-docs/manifest.sh"
. "$CD_LIB_DIR/claude-docs/framework.sh"
. "$CD_LIB_DIR/claude-docs/selection.sh"
. "$CD_LIB_DIR/claude-docs/files.sh"
. "$CD_LIB_DIR/claude-docs/render.sh"

cd_inject() { # template_dir, app_dir, module_value, app_value
  local tdir="$1" adir="$2" modval="$3" appval="$4"
  [ -n "$tdir" ] && [ -n "$adir" ] || fail "cd_inject: template_dir and app_dir required"
  [ -f "$tdir/CLAUDE.md" ] || fail "no CLAUDE.md in $tdir"
  [ -d "$tdir/.claude" ] || fail "no .claude/ in $tdir"

  local toks modtok apptok rel
  toks="$(cd_placeholders "$tdir")"
  modtok="${toks%%|*}"; apptok="${toks#*|}"
  [ -n "$modtok" ] && [ -n "$apptok" ] || fail "empty placeholder in $tdir/claude-docs.manifest"
  cd_validate_hook "$tdir"

  # Validate every destination before the first write. Never follow a link
  # inside the generated docs tree into another file or directory.
  for rel in .claude .claude/agents; do
    cd_validate_destination "$adir/$rel"
    if [ -e "$adir/$rel" ] && [ ! -d "$adir/$rel" ]; then
      fail "expected a directory: $adir/$rel"
    fi
  done
  while IFS= read -r rel; do
    cd_validate_destination "$adir/$rel"
    [ ! -d "$adir/$rel" ] || fail "expected a file destination: $adir/$rel"
  done < <(cd_selected_files "$tdir")

  while IFS= read -r rel; do
    cd_render_file "$(cd_source_file "$tdir" "$rel")" "$adir/$rel" \
      "$modtok" "$apptok" "$modval" "$appval" || return
  done < <(cd_selected_files "$tdir")
  cd_prune_index "$adir/CLAUDE.md" || return
  log "claude-docs: generated selected docs -> $adir, names rewritten to $modval/$appval"
}
