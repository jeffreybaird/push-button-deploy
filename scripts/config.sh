# Shared shell-config loading. Caller values (including explicit empty strings)
# override assignment keys in the file. The file remains trusted Bash, so normal
# quotes, multiline values, export assignments and variable expansion work.
# No values are written to temporary files, evaluated for restoration, or logged.

load_config() { # $1 config file, $2 key-only override reporter (optional)
  local __pbd_config_file="$1" __pbd_config_reporter="${2:-}"
  local __pbd_config_key __pbd_config_count=0 __pbd_config_i __pbd_config_status
  local __pbd_config_allexport=0
  local -a __pbd_config_keys __pbd_config_values
  [ -f "$__pbd_config_file" ] || return 0

  # Reserve __pbd_config_* for loader internals. Indexed arrays retain newlines,
  # quotes and literal shell syntax without a serialize/eval round trip.
  for __pbd_config_key in $(sed -nE 's/^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=.*/\2/p' "$__pbd_config_file" | sort -u); do
    case "$__pbd_config_key" in
      __pbd_config_*) printf 'config keys beginning __pbd_config_ are reserved\n' >&2; return 1 ;;
    esac
    if [ -n "${!__pbd_config_key+x}" ]; then
      __pbd_config_keys[$__pbd_config_count]="$__pbd_config_key"
      __pbd_config_values[$__pbd_config_count]="${!__pbd_config_key}"
      __pbd_config_count=$((__pbd_config_count + 1))
    fi
  done

  case $- in *a*) __pbd_config_allexport=1 ;; esac
  set -a
  # shellcheck disable=SC1090
  . "$__pbd_config_file"
  __pbd_config_status=$?
  if [ "$__pbd_config_allexport" -eq 0 ]; then set +a; fi

  for ((__pbd_config_i=0; __pbd_config_i<__pbd_config_count; __pbd_config_i++)); do
    __pbd_config_key="${__pbd_config_keys[$__pbd_config_i]}"
    if [ "${!__pbd_config_key-}" != "${__pbd_config_values[$__pbd_config_i]}" ] \
       && [ -n "$__pbd_config_reporter" ]; then
      "$__pbd_config_reporter" "$__pbd_config_key: using the caller's value instead of .env"
    fi
    printf -v "$__pbd_config_key" '%s' "${__pbd_config_values[$__pbd_config_i]}"
    export "$__pbd_config_key"
  done
  return "$__pbd_config_status"
}
