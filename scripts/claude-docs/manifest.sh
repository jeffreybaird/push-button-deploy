# Template manifest queries. Sourced by ../claude-docs.sh.

# ---- small helpers --------------------------------------------------------------

cd_in_list() { case " $2 " in *" $1 "*) return 0 ;; esac; return 1; }

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

