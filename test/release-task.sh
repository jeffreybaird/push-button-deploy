#!/usr/bin/env bash
# Offline regression checks: validation must never rewrite application code.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/lib/example"
cat > "$WORK/mix.exs" <<'EOF'
defmodule Example.MixProject do
  def project, do: [app: :example]
end
EOF
release="$WORK/lib/example/release.ex"

if bash "$ROOT/scripts/ensure-release-task.sh" --check "$WORK"; then
  echo 'FAIL: checking a missing release must fail' >&2; exit 1
fi
[ ! -e "$release" ]
bash "$ROOT/scripts/ensure-release-task.sh" "$WORK"
printf '\n# application-specific customization\n' >> "$release"
cp "$release" "$WORK/expected"
bash "$ROOT/scripts/ensure-release-task.sh" --check "$WORK"
cmp "$release" "$WORK/expected"
bash "$ROOT/scripts/ensure-release-task.sh" "$WORK"
cmp "$release" "$WORK/expected"

printf 'defmodule Other.Release do\nend\n' > "$release"
cp "$release" "$WORK/expected"
for mode in check generate; do
  if [ "$mode" = check ]; then set -- --check; else set --; fi
  if bash "$ROOT/scripts/ensure-release-task.sh" "$@" "$WORK"; then
    echo 'FAIL: an invalid existing release must fail' >&2; exit 1
  fi
  cmp "$release" "$WORK/expected"
done
echo 'release-task checks passed'
