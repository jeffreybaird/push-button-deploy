# Determine exactly which template files this run owns. No destination writes.

cd_validate_hook() {
  [ -z "${CD_NO_SETUP:-}" ] || return 0
  [ -n "${CD_HOOK:-}" ] || return 0
  case "$CD_HOOK" in
    *[!a-zA-Z0-9_-]*) fail "invalid hook variant '$CD_HOOK'" ;;
  esac
  [ -f "$1/.claude/settings.$CD_HOOK-hook.json" ] || fail "missing hook variant '$CD_HOOK' in $1"
}

cd_selected_files() { # template root -> relative destination paths, one per line
  local tdir="$1" src base
  printf 'CLAUDE.md\n'
  for src in "$tdir"/.claude/*.md; do
    [ -f "$src" ] || continue
    base="${src##*/}"
    cd_in_list "$base" "${CD_SKIP_MODULES:-}" && continue
    printf '.claude/%s\n' "$base"
  done
  for src in "$tdir"/.claude/agents/*.md; do
    [ -f "$src" ] || continue
    base="${src##*/}"
    cd_in_list "$base" "${CD_SKIP_AGENTS:-}" && continue
    printf '.claude/agents/%s\n' "$base"
  done
  if [ -z "${CD_NO_SETUP:-}" ]; then
    [ ! -f "$tdir/.claude/cloud-setup.sh" ] || printf '.claude/cloud-setup.sh\n'
    if [ -n "${CD_HOOK:-}" ] || [ -f "$tdir/.claude/settings.json" ]; then
      printf '.claude/settings.json\n'
    fi
  fi
  return 0
}

cd_source_file() { # template root, relative destination -> selected source
  if [ "$2" = .claude/settings.json ] && [ -n "${CD_HOOK:-}" ]; then
    printf '%s/.claude/settings.%s-hook.json\n' "$1" "$CD_HOOK"
  else
    printf '%s/%s\n' "$1" "$2"
  fi
}

cd_validate_destination() {
  [ ! -L "$1" ] || fail "refusing to overwrite symlink $1"
}
