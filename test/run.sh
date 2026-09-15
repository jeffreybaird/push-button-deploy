#!/usr/bin/env bash
# Run the repository's offline regression suites in isolated processes.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/work"

# Tests supply their own fixtures for cloud commands. An accidental real call
# fails the suite even when production code swallows that command's exit status.
for command in curl wget ssh scp gh doctl terraform docker; do
  cat > "$WORK/bin/$command" <<'GUARD'
#!/usr/bin/env bash
printf 'unexpected external command: %s\n' "$(basename "$0")" >> "$TEST_EXTERNAL_CALLS"
printf 'offline tests must mock %s\n' "$(basename "$0")" >&2
exit 97
GUARD
  chmod +x "$WORK/bin/$command"
done

for dependency in bash ruby jq perl; do
  command -v "$dependency" >/dev/null || { printf 'missing test dependency: %s\n' "$dependency" >&2; exit 1; }
done

failures=0
suites=0
run_suite() {
  local interpreter="$1" suite="$2" name status=0
  name="$(basename "$suite")"
  suites=$((suites + 1))
  : > "$WORK/external-calls"
  # Preserve the real HOME, but do not inherit cloud credentials or app config.
  # Git configuration is isolated so tests cannot invoke a user's signing hooks.
  env -i HOME="$HOME" PATH="$WORK/bin:$PATH" TMPDIR="$WORK/work" \
    LC_ALL=C GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    BASH_ENV="$ROOT/test/helpers/diagnostics.sh" \
    TEST_EXTERNAL_CALLS="$WORK/external-calls" \
    "$interpreter" "$suite" > "$WORK/$name.log" 2>&1 || status=$?
  if [ "$status" -eq 0 ] && [ ! -s "$WORK/external-calls" ]; then
    printf 'PASS %s\n' "$name"
  else
    printf 'FAIL %s (exit %s)\n' "$name" "$status" >&2
    cat "$WORK/$name.log" "$WORK/external-calls" >&2
    failures=$((failures + 1))
  fi
}

cd "$WORK/work"
for suite in "$ROOT"/test/*.sh; do
  [ "$(basename "$suite")" = run.sh ] && continue
  run_suite "$BASH" "$suite"
done
for suite in "$ROOT"/test/*.rb; do
  [ -f "$suite" ] || continue
  run_suite ruby "$suite"
done

# Parse the tool's shell sources as well as the tests, including new subfolders.
while IFS= read -r -d '' script; do
  if ! "$BASH" -n "$script"; then failures=$((failures + 1)); fi
done < <(find "$ROOT/scripts" "$ROOT/deploy" "$ROOT/test" -type f -name '*.sh' -print0)
for script in "$ROOT"/*.sh; do
  if ! "$BASH" -n "$script"; then failures=$((failures + 1)); fi
done
printf '\n%s suites; %s failure(s), including syntax checks\n' "$suites" "$failures"
[ "$failures" -eq 0 ]
