# Render only selected files; never traverse the application's existing docs.

cd_render_file() { # source, destination, module token, app token, module value, app value
  local src="$1" dest="$2"
  local layout="${7:-claude}"
  mkdir -p "$(dirname "$dest")" || return
  cp "$src" "$dest" || return
  # Translate template references before inserting application-specific names.
  # Settings stay in the tool's discovery location; the executable lives in doc/.
  case "$layout:$dest" in
    agents:*.md)
      perl -pi -e 's/CLAUDE\.md/AGENTS.md/g; s/\.claude\//doc\//g; s/Claude Code reads this every session\./Project guidance for coding agents./g;' "$dest" || return ;;
    *:*/settings.json)
      perl -pi -e 's{\.claude/cloud-setup\.sh}{doc/hooks/cloud-setup.sh}g;' "$dest" || return ;;
  esac
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

cd_prune_index() { # generated AGENTS.md
  local module prefix="$2"
  for module in ${CD_SKIP_MODULES:-}; do
    BASE="$module" PREFIX="$prefix" perl -ni -e 'print unless /^-\s+\x60\Q$ENV{PREFIX}\/$ENV{BASE}\E\x60/' "$1" || return
  done
}
