# Interactive selection only; file generation does not load prompt helpers.

# ---- guided selection ----------------------------------------------------------
#
# Prompts per optional module / agent / hook and sets the CD_SKIP_* globals.
# Loads prompt.sh when needed. Include is the default at every step.
cd_prompt_selection() { # $1 template_dir
  local tdir="$1" file summary hid hsum
  declare -F ask_yesno >/dev/null 2>&1 || . "$CD_LIB_DIR/prompt.sh"
  CD_SKIP_MODULES=""; CD_SKIP_AGENTS=""; CD_HOOK=""; CD_NO_SETUP=""

  while IFS='|' read -r file summary; do
    [ -n "$file" ] || continue
    ask_yesno "  include doc/$file — $summary?" y
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
  return 0
}

