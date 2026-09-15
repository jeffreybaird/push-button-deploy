# snake_case -> CamelCase (the derivation the scaffolds already use, centralized).
cd_camelize() {
  printf '%s' "$1" | awk -F_ '{o="";for(i=1;i<=NF;i++){o=o toupper(substr($i,1,1)) substr($i,2)} print o}'
}

# Framework detection and application naming. Sourced by ../claude-docs.sh.

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

