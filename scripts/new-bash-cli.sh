#!/usr/bin/env bash
#
# new-bash-cli.sh — scaffold a shell command-line program that behaves like a
# command. Invoked by bootstrap.sh's ensure_app for APP_TYPE=cli, LANGUAGE=bash
# (`./bootstrap.sh --cli bash <dir>`); also runnable by hand.
#
#   ./scripts/new-bash-cli.sh <app_dir>
#
# THIS IS THE ONE THE OTHERS ARE MEASURED AGAINST. A shell script is the easiest
# thing in the world to configure badly:
#
#   FORMAT=json ./foo.sh hello          # what this scaffold is NOT
#   foo --format json hello             # what it is
#
# So the generated tool parses arguments properly, in a loop that handles:
#
#   --flag value      --flag=value      -f value      -fvalue
#   -abc              (bundled short flags)
#   --                (end of options; everything after is positional)
#   --help  -h        --version  -v
#
# and exits 0 / 1 / 2 the way every other command does — 2 for a usage error, so
# a caller can tell "you typed it wrong" from "it ran and failed".
#
# THE SHAPE: a library with an executable on top of it.
#
#   lib/<name>/core.sh   the work, in functions that take arguments and echo
#   bin/<name>           argument parsing, then one call into the library
#
# bin/<name> is what you put on your PATH. core.sh is sourceable from another
# script, which is what "the library can be run as a CLI" means here.
#
# Dependency-free by construction: bash and coreutils, nothing to install, and
# the test suite is a plain script that runs the real executable. CI lints it
# too (`shellcheck -x`, which follows the source into the library).
#
# If <app_dir> already contains bin/<name> it is left alone.
#
# Portable: BSD/macOS bash, awk. The GENERATED tool targets bash 3.2 too — no
# associative arrays, no ${var,,}.
set -euo pipefail

fail() { printf 'new-bash-cli: %s\n' "$*" >&2; exit 1; }
log()  { printf '\033[32m==>\033[0m %s\n' "$*"; }

APP_DIR="${1:-}"
[ -n "$APP_DIR" ] || fail "usage: new-bash-cli.sh <app_dir>"

APP_NAME="$(basename "$APP_DIR")"
# Hyphens are allowed here where they are not for Ruby/Elixir: nothing derives a
# module or an atom from a shell tool's name, and `my-tool` is the natural
# spelling for a command.
case "$APP_NAME" in
  [a-z]*[!a-z0-9_-]*|*[!a-z0-9_-]*|[!a-z]*)
    fail "app name '$APP_NAME' must be lowercase letters, digits, '_' or '-' (start with a letter): the dir basename names the command" ;;
esac
# The shell-safe spelling, for variable and function prefixes.
APP_SYM="$(printf '%s' "$APP_NAME" | tr '-' '_')"

if [ -f "$APP_DIR/bin/$APP_NAME" ]; then
  log "bin/$APP_NAME already in $APP_DIR — leaving it alone"
  exit 0
fi
[ -d "$APP_DIR" ] && [ -n "$(ls -A "$APP_DIR" 2>/dev/null)" ] \
  && fail "$APP_DIR is not empty and has no bin/$APP_NAME — refusing to scaffold over it"

log "scaffolding bash CLI '$APP_NAME' in $APP_DIR"
mkdir -p "$APP_DIR/bin" "$APP_DIR/lib/$APP_NAME" "$APP_DIR/test"

printf '%s\n' "$APP_NAME" > "$APP_DIR/.app-name"

cat > "$APP_DIR/.gitignore" <<'EOF'
/tmp/
.env
EOF

cat > "$APP_DIR/.editorconfig" <<'EOF'
root = true

[*.sh]
indent_style = space
indent_size = 2

[bin/*]
indent_style = space
indent_size = 2
EOF

# ---- the library -----------------------------------------------------------------
cat > "$APP_DIR/lib/$APP_NAME/core.sh" <<EOF
#!/usr/bin/env bash
#
# The work. Functions that take arguments and write to stdout — they know
# nothing about flags, \$@, or exit codes, which is what lets bin/$APP_NAME stay
# a parser and the tests call these directly.
#
# Sourceable from another script:  . lib/$APP_NAME/core.sh

# ${APP_SYM}_greet <format> [words...]
#
# Renders a greeting. Returns 1 and writes nothing on an unknown format; the
# caller decides what to print about it.
${APP_SYM}_greet() {
  local format subject
  format="\$1"; shift
  if [ "\$#" -eq 0 ]; then subject="world"; else subject="\$*"; fi

  case "\$format" in
    text) printf 'hello %s\n' "\$subject" ;;
    json) printf '{"greeting":"hello","subject":"%s"}\n' "\$subject" ;;
    *)    return 1 ;;
  esac
}
EOF

# ---- the executable --------------------------------------------------------------
# The parser is the point of this file: everything a user types is handled here,
# and the last line is one call into the library.
cat > "$APP_DIR/bin/$APP_NAME" <<EOF
#!/usr/bin/env bash
#
# $APP_NAME — TODO: one sentence describing what it does.
#
# This file parses arguments and nothing else. The work is in
# lib/$APP_NAME/core.sh.
set -euo pipefail

VERSION="0.1.0"
PROG="\$(basename "\$0")"

# Resolve the real directory even through a symlink on the PATH, so the library
# is found whether the tool is run from a checkout, a PATH entry, or a symlink
# into one.
SELF="\${BASH_SOURCE[0]}"
while [ -L "\$SELF" ]; do
  DIR="\$(cd -P "\$(dirname "\$SELF")" && pwd)"
  SELF="\$(readlink "\$SELF")"
  case "\$SELF" in /*) ;; *) SELF="\$DIR/\$SELF" ;; esac
done
ROOT="\$(cd -P "\$(dirname "\$SELF")/.." && pwd)"

# The directive is what lets `shellcheck -x` (which CI runs, from the repo
# root — where this path resolves) follow the source and check the library in
# the same pass.
# shellcheck source=lib/$APP_NAME/core.sh
. "\$ROOT/lib/$APP_NAME/core.sh"

usage() {
  cat <<USAGE
\$PROG \$VERSION — TODO: one sentence describing what it does.

Usage:
  \$PROG [options] [words...]

Options:
  -f, --format FORMAT   output format: text (default) or json
  -h, --help            print this message
  -v, --version         print the version

Examples:
  \$PROG hello there
  \$PROG --format json hello there
  \$PROG -f json -- --not-a-flag
USAGE
}

# Exit 2 for a usage error — distinguishable from "ran fine" (0) and "ran and
# failed" (1), which is what lets a caller tell the two apart.
die_usage() {
  printf '%s: %s\n\n' "\$PROG" "\$1" >&2
  usage >&2
  exit 2
}

format="text"
args=""            # collected positionals, one per line (bash 3.2: no arrays needed)
end_of_options=0

# A value-taking option accepts both spellings. \`--format json\` consumes the
# next argument; \`--format=json\` carries its own.
need_value() { # \$1 flag name, \$2 the value or empty
  [ -n "\${2:-}" ] || die_usage "\$1 needs a value"
  printf '%s' "\$2"
}

while [ "\$#" -gt 0 ]; do
  if [ "\$end_of_options" -eq 1 ]; then
    args="\$args\$1
"
    shift; continue
  fi
  case "\$1" in
    --)              end_of_options=1; shift ;;
    -h|--help)       usage; exit 0 ;;
    -v|--version)    printf '%s %s\n' "\$PROG" "\$VERSION"; exit 0 ;;
    --format=*)      format="\$(need_value --format "\${1#--format=}")"; shift ;;
    -f|--format)     format="\$(need_value "\$1" "\${2:-}")"; shift 2 ;;
    -f*)             format="\$(need_value -f "\${1#-f}")"; shift ;;
    # Bundled short flags: -hv is -h -v. Re-queue them as separate arguments
    # rather than teaching every case arm about bundling.
    -[!-][!-]*)
      flags="\${1#-}"; shift
      set -- "\$(printf '%s' "\$flags" | cut -c1 | sed 's/^/-/')" "-\$(printf '%s' "\$flags" | cut -c2-)" "\$@" ;;
    --*)             die_usage "unknown option: \$1" ;;
    -?)              die_usage "unknown option: \$1" ;;
    *)               args="\$args\$1
"; shift ;;
  esac
done

# Split the collected positionals back into \$@ on newlines only, so an argument
# containing spaces survives.
OLDIFS="\$IFS"; IFS="
"
# shellcheck disable=SC2086
set -- \$args
IFS="\$OLDIFS"

if ! ${APP_SYM}_greet "\$format" "\$@"; then
  die_usage "unknown format: \$format (expected text or json)"
fi
EOF
chmod +x "$APP_DIR/bin/$APP_NAME"

# ---- tests -----------------------------------------------------------------------
# A plain script, not bats: nothing to install, runs identically on a laptop and
# on either CI provider, and it drives the REAL executable rather than a mock.
cat > "$APP_DIR/test/run.sh" <<EOF
#!/usr/bin/env bash
#
# The whole test suite. No framework, no dependencies:
#
#   ./test/run.sh
#
# Each case runs the real bin/$APP_NAME and asserts on its stdout and its exit
# status, which is the entire contract a command has with the people using it.
set -uo pipefail

ROOT="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")/.." && pwd)"
CLI="\$ROOT/bin/$APP_NAME"

pass=0; fail=0

# ok <description> <expected status> <expected stdout substring> -- <args...>
ok() {
  desc="\$1"; want_status="\$2"; want_out="\$3"; shift 4   # the 4th is the literal --
  out="\$("\$CLI" "\$@" 2>/dev/null)"; status=\$?
  if [ "\$status" != "\$want_status" ]; then
    printf 'FAIL %s\n     exit %s, wanted %s\n' "\$desc" "\$status" "\$want_status"; fail=\$((fail + 1)); return
  fi
  case "\$out" in
    *"\$want_out"*) printf 'ok   %s\n' "\$desc"; pass=\$((pass + 1)) ;;
    *) printf 'FAIL %s\n     stdout: %s\n     wanted to contain: %s\n' "\$desc" "\$out" "\$want_out"; fail=\$((fail + 1)) ;;
  esac
}

ok "no arguments greets the world"        0 "hello world"                    -- 
ok "positional arguments are joined"      0 "hello hi there"                 -- hi there
ok "--format with a space"                0 '"subject":"you"'                -- --format json you
ok "--format=value"                       0 '"subject":"you"'                -- --format=json you
ok "-f with a space"                      0 '"subject":"world"'              -- -f json
ok "-fvalue attached"                     0 '"subject":"world"'              -- -fjson
ok "-- ends the options"                  0 "hello --format"                 -- -- --format
ok "--help prints usage"                  0 "Usage:"                         -- --help
ok "-h prints usage"                      0 "Usage:"                         -- -h
ok "--version prints the version"         0 "$APP_NAME 0.1.0"                -- --version
ok "unknown option exits 2"               2 ""                               -- --nope
ok "unknown format exits 2"               2 ""                               -- --format yaml
ok "a flag missing its value exits 2"     2 ""                               -- --format

printf '\n%s passed, %s failed\n' "\$pass" "\$fail"
[ "\$fail" -eq 0 ]
EOF
chmod +x "$APP_DIR/test/run.sh"

cat > "$APP_DIR/README.md" <<EOF
# $APP_NAME

TODO: one sentence describing $APP_NAME.

## Run it

    ./bin/$APP_NAME --help
    ./bin/$APP_NAME --format json hello there

Put it on your PATH and it is just a command:

    ln -s "\$PWD/bin/$APP_NAME" ~/.local/bin/$APP_NAME
    $APP_NAME --format json hello there

It takes **arguments**, not environment variables: \`--format json\`,
\`--format=json\`, \`-f json\`, \`-fjson\` and \`--\` all work, \`--help\` and
\`--version\` do what you expect, and a usage error exits 2 rather than 1.

## Shape

\`lib/$APP_NAME/core.sh\` holds the work as functions that take arguments and
write to stdout; it is sourceable from any other script. \`bin/$APP_NAME\` parses
arguments and makes one call into it. That split is why the tool can be both a
command and a library.

## Develop

    ./test/run.sh        # the whole suite — no framework, nothing to install
    shellcheck -x bin/$APP_NAME lib/$APP_NAME/*.sh test/run.sh

## Pipeline

Every push runs \`.github/workflows/ci.yml\` (or \`.gitea/workflows/ci.yml\`):
shellcheck, then the test suite.

This project provisions no infrastructure — no droplet, no DNS, no database.
It was created with \`bootstrap.sh --cli bash\`.
EOF

log "scaffolded $APP_DIR (bash cli): bin/$APP_NAME, lib/$APP_NAME/core.sh, test/run.sh"
