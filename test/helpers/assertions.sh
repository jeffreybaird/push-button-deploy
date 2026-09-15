# Expected-negative assertion. A bare `! command` is exempt from Bash errexit,
# so it can silently keep a suite green when the command unexpectedly succeeds.
# Exit 1 means a negative match; exit 2+ means the assertion itself broke.
assert_not() {
  local status=0
  "$@" >/dev/null 2>&1 || status=$?
  if [ "$status" -ne 1 ]; then
    printf 'negative assertion failed (expected exit 1, got %s): %s\n' "$status" "$1" >&2
    return 1
  fi
}
