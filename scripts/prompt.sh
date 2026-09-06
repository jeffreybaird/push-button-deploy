# scripts/prompt.sh — interactive terminal prompt helpers.
#
# A tiny, self-contained set of prompt primitives used by any command that
# walks a user through choices one at a time: bootstrap.sh's --interactive
# mode and claude-docs.sh's guided doc generation both source this.
#
# Requires from the sourcing script: fail() already defined (called when the
# terminal closes mid-prompt). Nothing else — these functions carry no
# command-specific state.
#
# THE CONTRACT. Each prompt writes to stderr and sets $REPLY_VALUE — it does
# NOT echo the answer for a `$(...)` to capture. That is deliberate: a command
# substitution runs in a subshell, and a fail() (e.g. the terminal closing
# mid-session) from inside one would only kill the subshell, leaving the parent
# to march on with an empty value. Setting a global keeps every fail() in the
# main shell, where it actually stops the run. Answers are read from /dev/tty,
# so a redirected or piped stdin never swallows a prompt — and ask_menu can take
# its option list on its own stdin (via process substitution) without the two
# contending.
#
# Portable: BSD/macOS bash.

REPLY_VALUE=""

ask_line() { # $1 prompt -> sets REPLY_VALUE to the entered line (empty on Enter)
  printf '%s' "$1" >&2
  IFS= read -r REPLY_VALUE < /dev/tty \
    || fail "interactive: input closed — this mode needs a terminal (use the flags instead)"
}

ask_text() { # $1 label, $2 default -> REPLY_VALUE (the default on empty input)
  local d="$2"
  ask_line "$1${d:+ [$d]}: "
  [ -n "$REPLY_VALUE" ] || REPLY_VALUE="$d"
}

ask_yesno() { # $1 label, $2 default (y/n) -> REPLY_VALUE 'true' or 'false'
  local d="$2"
  while :; do
    ask_line "$1 (y/n) [$d]: "; [ -n "$REPLY_VALUE" ] || REPLY_VALUE="$d"
    case "$REPLY_VALUE" in
      y|Y|yes|true)  REPLY_VALUE=true;  return ;;
      n|N|no|false)  REPLY_VALUE=false; return ;;
      *) printf '  please answer y or n\n' >&2 ;;
    esac
  done
}

# Numbered menu. Options arrive on stdin as `value|description` lines; the
# chosen VALUE lands in REPLY_VALUE. A bare Enter takes the default (marked *);
# a name is accepted as readily as its number.
ask_menu() { # $1 label, $2 default-value  (options on stdin)
  local label="$1" default="$2" val desc n=0 i
  local -a vals=() descs=()
  while IFS='|' read -r val desc; do
    [ -n "$val" ] || continue
    n=$((n + 1)); vals+=("$val"); descs+=("$desc")
  done
  printf '\n%s\n' "$label" >&2
  for ((i = 1; i <= n; i++)); do
    local mark=" "; [ "${vals[i-1]}" = "$default" ] && mark="*"
    printf '  %s%s) %-10s %s\n' "$mark" "$i" "${vals[i-1]}" "${descs[i-1]}" >&2
  done
  while :; do
    ask_line "choice [$default]: "; [ -n "$REPLY_VALUE" ] || REPLY_VALUE="$default"
    for ((i = 1; i <= n; i++)); do
      [ "$REPLY_VALUE" = "${vals[i-1]}" ] && return
    done
    case "$REPLY_VALUE" in
      ''|*[!0-9]*) ;;
      *) if [ "$REPLY_VALUE" -ge 1 ] && [ "$REPLY_VALUE" -le "$n" ]; then
           REPLY_VALUE="${vals[REPLY_VALUE-1]}"; return
         fi ;;
    esac
    printf '  pick 1-%s, or a name\n' "$n" >&2
  done
}
