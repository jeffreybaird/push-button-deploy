# Loaded by the offline runner through BASH_ENV, including child Bash processes.
# Report source location, not command text: fixture values need not enter logs.
set -E
trap 'printf "test command failed at %s:%s (exit %s)\n" "${BASH_SOURCE[0]:-shell}" "$LINENO" "$?" >&2' ERR
