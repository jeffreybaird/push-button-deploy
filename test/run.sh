#!/usr/bin/env bash
#
# The whole test suite for the pbd command itself:
#
#   ./test/run.sh
#
# No framework and nothing to install — the same shape the bash CLIs this tool
# scaffolds are given (scripts/new-bash-cli.sh), for the same reason: it runs
# identically on a laptop and on either CI provider, and it drives the REAL
# executable rather than a mock.
#
# What it covers is the CLI CONTRACT, not the deploys: which commands exist,
# what they print, what they exit with, and — the part the conversion to a
# command was for — that the tool finds its templates and its state in the right
# places whether it is run from a checkout, through a symlink on the PATH, or
# from an install prefix somewhere else entirely. Nothing here provisions
# anything or needs a credential.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$ROOT/bin/pbd"

# A sandbox for state, so a test run never touches the real one.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export PBD_STATE_DIR="$TMP/state"
export XDG_CONFIG_HOME="$TMP/config"   # so a real ~/.config/pbd/env can't leak in

pass=0; fail=0

# ok <description> <expected status> <expected stdout+stderr substring> -- <args...>
ok() {
  local desc="$1" want_status="$2" want_out="$3"; shift 4   # the 4th is the literal --
  local out status
  out="$("$CLI" "$@" 2>&1)"; status=$?
  if [ "$status" != "$want_status" ]; then
    printf 'FAIL %s\n     exit %s, wanted %s\n     output: %s\n' "$desc" "$status" "$want_status" "$out"
    fail=$((fail + 1)); return
  fi
  case "$out" in
    *"$want_out"*) printf 'ok   %s\n' "$desc"; pass=$((pass + 1)) ;;
    *) printf 'FAIL %s\n     output: %s\n     wanted to contain: %s\n' "$desc" "$out" "$want_out"
       fail=$((fail + 1)) ;;
  esac
}

# check <description> — asserts on the command that follows
check() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then printf 'ok   %s\n' "$desc"; pass=$((pass + 1))
  else printf 'FAIL %s\n     failed: %s\n' "$desc" "$*"; fail=$((fail + 1)); fi
}

printf '== the command itself ==\n'
ok "no arguments prints usage and exits 2"  2 "Usage:"            --
ok "--help prints usage"                    0 "Usage:"            -- --help
ok "-h prints usage"                        0 "Usage:"            -- -h
ok "help prints usage"                      0 "Usage:"            -- help
ok "--version prints the version"           0 "pbd 0"             -- --version
ok "-v prints the version"                  0 "pbd 0"             -- -v
ok "version prints the version"             0 "pbd 0"             -- version
ok "an unknown command exits 2"             2 "no such command"   -- nonesuch
ok "an unknown global option exits 2"       2 "unknown option"    -- --nonesuch
ok "help for an unknown command exits 2"    2 "no such command"   -- help nonesuch

printf '\n== the version is one number, in one file ==\n'
ok "--version matches VERSION" 0 "pbd $(tr -d '[:space:]' < "$ROOT/VERSION")" -- --version

printf '\n== each command answers for itself ==\n'
ok "help bootstrap describes bootstrap"     0 "pbd bootstrap —"   -- help bootstrap
ok "bootstrap --help describes bootstrap"   0 "pbd bootstrap —"   -- bootstrap --help
ok "bootstrap --help lists the app types"   0 "--cli"             -- bootstrap --help
ok "help teardown describes teardown"       0 "pbd teardown —"    -- help teardown
ok "teardown --help describes teardown"     0 "pbd teardown —"    -- teardown --help
ok "gitea --help lists its subcommands"     0 "pbd gitea teardown" -- gitea --help
ok "gitea with no subcommand exits 2"       2 "pbd gitea"         -- gitea
ok "gitea bootstrap --help"                 0 "pbd gitea bootstrap —" -- gitea bootstrap --help
ok "gitea teardown --help"                  0 "pbd gitea teardown —"  -- gitea teardown --help
ok "an unknown gitea subcommand exits 2"    2 "no such gitea command" -- gitea nonesuch

printf '\n== usage errors are 2, not 1 ==\n'
# The distinction a caller relies on: "you typed it wrong" vs "it ran and failed".
ok "an unknown bootstrap option exits 2"    2 "unknown argument"  -- bootstrap --nonesuch
ok "--lang without a value exits 2"         2 "needs a language"  -- bootstrap --lang
ok "--host without a value exits 2"         2 "needs the host"    -- bootstrap --host
ok "an unknown teardown option exits 2"     2 "unknown argument"  -- teardown --nonesuch
ok "conflicting app types exit non-zero"    1 "conflicting app types" -- bootstrap --cli --service

printf '\n== it knows where its own files are ==\n'
ok "config reports the root"       0 "root         $ROOT"       -- config
ok "config reports the state dir"  0 "state        $PBD_STATE_DIR" -- config
check "the state directory is created on demand" test -d "$PBD_STATE_DIR"
check "the templates it reports are really there" test -f "$ROOT/infra-persistent/main.tf"

printf '\n== through a symlink on the PATH ==\n'
# The Homebrew shape: bin/pbd is a symlink from somewhere else entirely, and the
# templates must still be found next to the file it points AT.
mkdir -p "$TMP/bin"
ln -sf "$CLI" "$TMP/bin/pbd"
out="$("$TMP/bin/pbd" config 2>&1)"
case "$out" in
  *"root         $ROOT"*) printf 'ok   a symlinked pbd resolves the real root\n'; pass=$((pass + 1)) ;;
  *) printf 'FAIL a symlinked pbd resolves the real root\n     output: %s\n' "$out"; fail=$((fail + 1)) ;;
esac

printf '\n== from an install prefix (what brew produces) ==\n'
# Copy the tree the way the formula does and run it from there: same layout,
# different directory, no checkout anywhere in sight.
PREFIX="$TMP/prefix"
mkdir -p "$PREFIX"
tar -c -C "$ROOT" bin lib scripts infra-persistent infra-app infra-state infra-tenant \
    infra-gitea app deploy app-template app-template-ruby app-template-zola gitea-host VERSION \
  | tar -x -C "$PREFIX"
mkdir -p "$TMP/installed-bin"
ln -sf "$PREFIX/bin/pbd" "$TMP/installed-bin/pbd"
out="$("$TMP/installed-bin/pbd" config 2>&1)"
case "$out" in
  *"root         $PREFIX"*) printf 'ok   an installed pbd uses its own prefix\n'; pass=$((pass + 1)) ;;
  *) printf 'FAIL an installed pbd uses its own prefix\n     output: %s\n' "$out"; fail=$((fail + 1)) ;;
esac
out="$("$TMP/installed-bin/pbd" bootstrap --help 2>&1)"
case "$out" in
  *"pbd bootstrap —"*) printf 'ok   an installed pbd loads its own library\n'; pass=$((pass + 1)) ;;
  *) printf 'FAIL an installed pbd loads its own library\n     output: %s\n' "$out"; fail=$((fail + 1)) ;;
esac
# Nothing was written into the prefix — the whole point of the state split.
if [ -z "$(find "$PREFIX" -name '*.log' -o -name '.gitea-admin-*' 2>/dev/null)" ]; then
  printf 'ok   an installed pbd writes nothing into its prefix\n'; pass=$((pass + 1))
else
  printf 'FAIL an installed pbd writes nothing into its prefix\n     found: %s\n' \
    "$(find "$PREFIX" -name '*.log' -o -name '.gitea-admin-*')"; fail=$((fail + 1))
fi

printf '\n== an incomplete installation says so ==\n'
out="$(PBD_ROOT="$TMP" "$CLI" config 2>&1)"; status=$?
if [ "$status" != 0 ] && case "$out" in *"installation looks incomplete"*) true ;; *) false ;; esac; then
  printf 'ok   a PBD_ROOT with no library is refused\n'; pass=$((pass + 1))
else
  printf 'FAIL a PBD_ROOT with no library is refused\n     exit %s, output: %s\n' "$status" "$out"
  fail=$((fail + 1))
fi

printf '\n== configuration ==\n'
# The env file is SEARCHED for, not assumed to sit beside the script — that
# assumption is exactly what does not survive being installed.
mkdir -p "$XDG_CONFIG_HOME/pbd"
printf 'DNS_ZONE=from-xdg.example\n' > "$XDG_CONFIG_HOME/pbd/env"
printf 'DNS_ZONE=from-flag.example\n' > "$TMP/other.env"
ok "an XDG env file is found"     0 "$XDG_CONFIG_HOME/pbd/env" -- config
ok "--env-file wins over the XDG one" 0 "$TMP/other.env" -- --env-file "$TMP/other.env" config
ok "--env-file=PATH also works"   0 "$TMP/other.env"  -- "--env-file=$TMP/other.env" config
ok "a missing env file is an error, not a silent fall-through" \
                                  1 "does not exist"  -- --env-file "$TMP/nope.env" config
ok "--env-file with no path exits 2" 2 "needs a path" -- --env-file
rm -f "$XDG_CONFIG_HOME/pbd/env"
ok "no env file anywhere is fine" 0 "(none found"     -- config

printf '\n== the deprecated entry points still work ==\n'
for pair in "bootstrap.sh:pbd bootstrap" "teardown.sh:pbd teardown" \
            "bootstrap-gitea.sh:pbd gitea bootstrap" "teardown-gitea.sh:pbd gitea teardown"; do
  script="${pair%%:*}"; want="${pair#*:}"
  out="$("$ROOT/$script" --help 2>&1)"
  if case "$out" in *"deprecated"*"$want"*) true ;; *) false ;; esac; then
    printf 'ok   ./%s forwards to `%s`\n' "$script" "$want"; pass=$((pass + 1))
  else
    printf 'FAIL ./%s forwards to `%s`\n     output: %s\n' "$script" "$want" "$out"; fail=$((fail + 1))
  fi
done

printf '\n== every shipped script parses ==\n'
while IFS= read -r f; do
  if bash -n "$f" 2>/dev/null; then pass=$((pass + 1))
  else printf 'FAIL %s does not parse\n' "$f"; fail=$((fail + 1)); fi
done <<EOF
$(find "$ROOT/bin" "$ROOT/lib" "$ROOT/scripts" "$ROOT/deploy" -type f \( -name '*.sh' -o -name 'pbd' \) | sort)
$ROOT/bootstrap.sh
$ROOT/teardown.sh
$ROOT/bootstrap-gitea.sh
$ROOT/teardown-gitea.sh
EOF
printf 'ok   bash -n over bin/, lib/, scripts/, deploy/ and the shims\n'

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
