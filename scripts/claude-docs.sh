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
# absent) and, for the guided flow, prompt.sh (sourced here if not already).
#
# Portable: BSD/macOS bash, awk, perl.

CD_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CD_ROOT="$(cd "$CD_LIB_DIR/.." && pwd)"

# shellcheck source=prompt.sh
declare -F ask_yesno >/dev/null 2>&1 || . "$CD_LIB_DIR/prompt.sh"
declare -F fail >/dev/null 2>&1 || fail() { printf 'claude-docs: %s\n' "$*" >&2; exit 1; }
declare -F log  >/dev/null 2>&1 || log()  { printf '\033[32m==>\033[0m %s\n' "$*"; }

# ---- small helpers --------------------------------------------------------------

cd_in_list() { case " $2 " in *" $1 "*) return 0 ;; esac; return 1; }

# snake_case -> CamelCase (the derivation the scaffolds already use, centralized).
cd_camelize() {
  printf '%s' "$1" | awk -F_ '{o="";for(i=1;i<=NF;i++){o=o toupper(substr($i,1,1)) substr($i,2)} print o}'
}

# ---- manifest ------------------------------------------------------------------

# The two placeholder strings a template uses, "MODTOK|APPTOK". Defaults to the
# app-template pair when a root ships no manifest.
cd_placeholders() { # $1 template_dir
  local m="$1/claude-docs.manifest" line
  if [ -f "$m" ]; then
    line="$(awk -F'|' '$1=="placeholders"{print $2"|"$3; exit}' "$m")"
    [ -n "$line" ] && { printf '%s\n' "$line"; return; }
  fi
  printf 'MyApp|my_app\n'
}

# Rows of a given role as "arg1|arg2" lines (optional / agent / hook).
cd_manifest_rows() { # $1 template_dir, $2 role
  local m="$1/claude-docs.manifest"
  [ -f "$m" ] || return 0
  awk -F'|' -v r="$2" '$1==r{print $2"|"$3}' "$m"
}

# ---- framework <-> template (only the roots that exist today) -------------------

cd_frameworks() { printf 'phoenix sinatra zola\n'; }

cd_template_dir() { # $1 framework -> template root path (empty if unknown)
  case "$1" in
    phoenix) printf '%s\n' "$CD_ROOT/app-template" ;;
    sinatra) printf '%s\n' "$CD_ROOT/app-template-ruby" ;;
    zola)    printf '%s\n' "$CD_ROOT/app-template-zola" ;;
  esac
}

# Guess the framework of an existing app from its marker file.
cd_infer_framework() { # $1 dir -> framework or empty
  [ -f "$1/mix.exs" ]     && { printf 'phoenix\n'; return; }
  [ -f "$1/Gemfile" ]     && { printf 'sinatra\n'; return; }
  [ -f "$1/config.toml" ] && { printf 'zola\n';    return; }
  return 0
}

# The placeholder VALUES for an app: "MODVAL|APPVAL". Phoenix reads mix.exs when
# present (via app-meta.sh); otherwise all three derive from the dir basename.
cd_values_for() { # $1 framework, $2 app_dir
  local fw="$1" dir="$2" base name title
  base="$(basename "$dir")"
  case "$fw" in
    phoenix)
      if [ -f "$dir/mix.exs" ]; then
        # shellcheck source=app-meta.sh
        . "$CD_ROOT/scripts/app-meta.sh"
        printf '%s|%s\n' "$(app_module "$dir")" "$(app_name "$dir")"
      else
        name="$(printf '%s' "$base" | tr '-' '_')"
        printf '%s|%s\n' "$(cd_camelize "$name")" "$name"
      fi ;;
    sinatra)
      name="$(printf '%s' "$base" | tr '-' '_')"
      printf '%s|%s\n' "$(cd_camelize "$name")" "$name" ;;
    zola)
      title="$(printf '%s' "$base" | tr '_-' '  ' | awk '{for(i=1;i<=NF;i++){$i=toupper(substr($i,1,1)) substr($i,2)}; print}')"
      printf '%s|%s\n' "$title" "$base" ;;
    *) fail "claude-docs: no value derivation for framework '$fw'" ;;
  esac
}

# ---- guided selection ----------------------------------------------------------
#
# Prompts per optional module / agent / hook and sets the CD_SKIP_* globals.
# Requires prompt.sh (sourced at load). Include is the default at every step.
cd_prompt_selection() { # $1 template_dir
  local tdir="$1" file summary hid hsum
  CD_SKIP_MODULES=""; CD_SKIP_AGENTS=""; CD_HOOK=""; CD_NO_SETUP=""

  while IFS='|' read -r file summary; do
    [ -n "$file" ] || continue
    ask_yesno "  include .claude/$file — $summary?" y
    [ "$REPLY_VALUE" = true ] || CD_SKIP_MODULES="$CD_SKIP_MODULES $file"
  done < <(cd_manifest_rows "$tdir" optional)

  while IFS='|' read -r file summary; do
    [ -n "$file" ] || continue
    ask_yesno "  include agent $file — $summary?" y
    [ "$REPLY_VALUE" = true ] || CD_SKIP_AGENTS="$CD_SKIP_AGENTS $file"
  done < <(cd_manifest_rows "$tdir" agent)

  if [ -f "$tdir/.claude/settings.json" ]; then
    ask_yesno "  include the SessionStart cloud-setup hook (recommended for cloud sessions)?" y
    if [ "$REPLY_VALUE" = true ]; then
      while IFS='|' read -r hid hsum; do
        [ -n "$hid" ] || continue
        [ -f "$tdir/.claude/settings.$hid-hook.json" ] || continue
        ask_yesno "  also add the '$hid' hook — $hsum?" n
        [ "$REPLY_VALUE" = true ] && CD_HOOK="$hid"
      done < <(cd_manifest_rows "$tdir" hook)
    else
      CD_NO_SETUP=1
    fi
  fi
}

# ---- injection -----------------------------------------------------------------

cd_inject() { # $1 template_dir, $2 app_dir, $3 mod_val, $4 app_val
  local tdir="$1" adir="$2" modval="$3" appval="$4"
  if [ -z "$tdir" ] || [ -z "$adir" ]; then fail "cd_inject: template_dir and app_dir required"; fi
  [ -f "$tdir/CLAUDE.md" ] || fail "no CLAUDE.md in $tdir"
  [ -d "$tdir/.claude" ]   || fail "no .claude/ in $tdir"

  local toks modtok apptok
  toks="$(cd_placeholders "$tdir")"; modtok="${toks%%|*}"; apptok="${toks#*|}"

  mkdir -p "$adir/.claude"
  cp "$tdir/CLAUDE.md" "$adir/CLAUDE.md"

  # guidance modules (skip excluded optionals)
  local src base count=0 acount=0
  for src in "$tdir"/.claude/*.md; do
    [ -e "$src" ] || continue
    base="$(basename "$src")"
    cd_in_list "$base" "${CD_SKIP_MODULES:-}" && continue
    cp "$src" "$adir/.claude/$base"; count=$((count + 1))
  done

  # agents (skip excluded); only create the dir if something lands in it
  if [ -d "$tdir/.claude/agents" ]; then
    for src in "$tdir"/.claude/agents/*.md; do
      [ -e "$src" ] || continue
      base="$(basename "$src")"
      cd_in_list "$base" "${CD_SKIP_AGENTS:-}" && continue
      mkdir -p "$adir/.claude/agents"
      cp "$src" "$adir/.claude/agents/$base"; acount=$((acount + 1))
    done
  fi

  # SessionStart cloud-setup hook + settings (unless opted out)
  if [ -z "${CD_NO_SETUP:-}" ]; then
    if [ -f "$tdir/.claude/cloud-setup.sh" ]; then
      cp "$tdir/.claude/cloud-setup.sh" "$adir/.claude/cloud-setup.sh"
      chmod +x "$adir/.claude/cloud-setup.sh"
    fi
    if [ -n "${CD_HOOK:-}" ] && [ -f "$tdir/.claude/settings.$CD_HOOK-hook.json" ]; then
      cp "$tdir/.claude/settings.$CD_HOOK-hook.json" "$adir/.claude/settings.json"
    elif [ -f "$tdir/.claude/settings.json" ]; then
      cp "$tdir/.claude/settings.json" "$adir/.claude/settings.json"
    fi
  fi

  # placeholder rewrite over docs (incl. agents) + the cloud-setup script.
  # The perl program is single-quoted on purpose — $ENV{...} is perl, not shell.
  # shellcheck disable=SC2016
  find "$adir/CLAUDE.md" "$adir/.claude" \
    \( -name '*.md' -o -name 'cloud-setup.sh' \) -type f -print0 \
    | MODTOK="$modtok" MODVAL="$modval" APPTOK="$apptok" APPVAL="$appval" \
        xargs -0 perl -pi -e 's/\Q$ENV{MODTOK}\E/$ENV{MODVAL}/g; s/\Q$ENV{APPTOK}\E/$ENV{APPVAL}/g;'

  # drop the index bullet for each skipped optional module so CLAUDE.md never
  # points at a file that wasn't copied. Matches only the "- `.claude/x.md`"
  # index bullets, never prose references elsewhere in the file.
  local m
  for m in ${CD_SKIP_MODULES:-}; do
    # shellcheck disable=SC2016  # $ENV{BASE} is perl, not shell — single quotes intended
    BASE="$m" perl -ni -e 'print unless /^-\s+\x60\Q.claude\/$ENV{BASE}\E\x60/' "$adir/CLAUDE.md"
  done

  local extra=""
  [ "$acount" -gt 0 ] && extra=" + $acount agent(s)"
  [ -n "${CD_HOOK:-}" ] && extra="$extra + $CD_HOOK hook"
  [ -n "${CD_NO_SETUP:-}" ] && extra="$extra (no cloud hook)"
  log "claude-docs: CLAUDE.md + $count module(s)$extra -> $adir, names rewritten to $modval/$appval"
}
