# Render only selected files; never traverse the application's existing docs.

cd_render_file() { # source, destination, module token, app token, module value, app value
  local src="$1" dest="$2"
  mkdir -p "$(dirname "$dest")" || return
  cp "$src" "$dest" || return
  case "$dest" in
    *.md|*/cloud-setup.sh)
      # One pass prevents inserted values from being rewritten as tokens.
      MODTOK="$3" APPTOK="$4" MODVAL="$5" APPVAL="$6" perl -pi -e '
        BEGIN {
          %values = ($ENV{MODTOK} => $ENV{MODVAL}, $ENV{APPTOK} => $ENV{APPVAL});
          $tokens = join "|", map { quotemeta($_) }
            sort { length($b) <=> length($a) } keys %values;
        }
        s/($tokens)/$values{$1}/g;
      ' "$dest" || return ;;
  esac
  if [ "${dest##*/}" = cloud-setup.sh ]; then chmod +x "$dest" || return; fi
}

cd_prune_index() { # generated CLAUDE.md
  local module
  for module in ${CD_SKIP_MODULES:-}; do
    BASE="$module" perl -ni -e 'print unless /^-\s+\x60\Q.claude\/$ENV{BASE}\E\x60/' "$1" || return
  done
}
