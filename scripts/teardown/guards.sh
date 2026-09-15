# Track exact paths and preserve preexisting override files during teardown.
TD_GUARD_FILES=()
TD_GUARD_BACKUPS=()
TD_GUARD_TEMP=""

teardown_lift_guard() { # root, resource type, resource name, optional attributes
  local file="$1/teardown_override.tf" index found=0 backup
  [ ! -L "$file" ] || fail "refusing symlink override: $file"
  for ((index=0; index<${#TD_GUARD_FILES[@]}; index++)); do
    [ "${TD_GUARD_FILES[$index]}" != "$file" ] || found=1
  done
  if [ "$found" = 0 ]; then
    [ -n "$TD_GUARD_TEMP" ] || TD_GUARD_TEMP="$(mktemp -d)" || return
    index=${#TD_GUARD_FILES[@]}
    backup=""
    if [ -e "$file" ]; then
      backup="$TD_GUARD_TEMP/$index"
      cp -p "$file" "$backup" || return
    fi
    TD_GUARD_FILES[$index]="$file"
    TD_GUARD_BACKUPS[$index]="$backup"
    : > "$file" || return
  fi
  {
    printf 'resource "%s" "%s" {\n' "$2" "$3"
    if [ -n "${4:-}" ]; then printf '  %s\n' "$4"; fi
    printf '  lifecycle { prevent_destroy = false }\n}\n'
  } >> "$file"
}

teardown_restore_guards() {
  local i failed=0
  for ((i=0; i<${#TD_GUARD_FILES[@]}; i++)); do
    if [ -n "${TD_GUARD_BACKUPS[$i]}" ]; then
      cp -p "${TD_GUARD_BACKUPS[$i]}" "${TD_GUARD_FILES[$i]}" || failed=1
    else
      rm -f "${TD_GUARD_FILES[$i]}" || failed=1
    fi
  done
  if [ "$failed" = 0 ]; then
    [ -z "$TD_GUARD_TEMP" ] || rm -rf "$TD_GUARD_TEMP"
  else
    printf 'teardown: override restoration failed; backups retained in %s\n' "$TD_GUARD_TEMP" >&2
  fi
  return "$failed"
}

teardown_on_exit() {
  local status="$1"
  teardown_restore_guards || status=1
  if [ "$status" -ne 0 ]; then printf 'teardown failed (exit %s); inspect completed steps before rerunning.\n' "$status" >&2; fi
  exit "$status"
}
