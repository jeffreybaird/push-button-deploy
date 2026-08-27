#!/usr/bin/env bash
#
# new-mix-app.sh — scaffold a runnable Elixir project that is NOT a web service:
# a plain library (FRAMEWORK=mix) or a command-line escript (FRAMEWORK=escript).
# Invoked by bootstrap.sh's ensure_app for the droplet-free app types; also
# runnable by hand.
#
#   ./scripts/new-mix-app.sh [--lib|--escript] <app_dir>
#
#   --lib      (default) a library: mix.exs, lib/, test/. Nothing to run.
#   --escript  a CLI: the above plus lib/<name>/cli.ex and the escript config,
#              so `mix escript.build` produces one self-contained executable.
#
# WHY PURE BASH, with no `mix` involved: the same reason new-zola-site.sh and
# new-sinatra-app.sh are. The scaffold is written by hand and the build runs in
# CI, so standing up a gem, a package or a CLI needs nothing installed locally
# beyond git — which is the whole point of the droplet-free types. `mix new`
# would drag an Elixir toolchain into a path that otherwise requires none.
#
# What this writes is `mix format`-clean as emitted. The CI workflow it ships
# with runs `mix format --check-formatted` as its first step, so a scaffold that
# was merely close would hand every new project a red first run.
#
# BEAM version pins come from app/Dockerfile's ARGs — the same Elixir/OTP the
# containerized path builds with, so there is one place in this repo to bump
# them. Override per-run with ELIXIR_VERSION / OTP_VERSION.
#
# If <app_dir> already contains a mix.exs it is left completely alone: this
# script only ever creates a project, it never retrofits one.
#
# Portable: BSD/macOS bash, awk, sed.
set -euo pipefail

fail() { printf 'new-mix-app: %s\n' "$*" >&2; exit 1; }
log()  { printf '\033[32m==>\033[0m %s\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKERFILE="$SCRIPT_DIR/../app/Dockerfile"

KIND=lib
APP_DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --lib)     KIND=lib; shift ;;
    --escript) KIND=escript; shift ;;
    -*)        fail "unknown argument: $1 (use --lib, --escript, <app_dir>)" ;;
    *)         APP_DIR="$1"; shift ;;
  esac
done
[ -n "$APP_DIR" ] || fail "usage: new-mix-app.sh [--lib|--escript] <app_dir>"

APP_NAME="$(basename "$APP_DIR")"
case "$APP_NAME" in
  [a-z]*[!a-z0-9_]*|*[!a-z0-9_]*|[!a-z]*)
    fail "app name '$APP_NAME' must be lower_snake_case (start with a letter): the dir basename names the OTP application" ;;
esac
APP_MODULE="$(printf '%s' "$APP_NAME" | awk -F_ '{o=""; for(i=1;i<=NF;i++){o=o toupper(substr($i,1,1)) substr($i,2)} print o}')"

if [ -f "$APP_DIR/mix.exs" ]; then
  log "mix.exs already in $APP_DIR — leaving it alone"
  exit 0
fi
[ -d "$APP_DIR" ] && [ -n "$(ls -A "$APP_DIR" 2>/dev/null)" ] \
  && fail "$APP_DIR is not empty and has no mix.exs — refusing to scaffold over it"

# ---- toolchain pins --------------------------------------------------------------
# app/Dockerfile is this repo's single source of truth for the BEAM versions.
dockerfile_arg() { sed -nE "s/^ARG $1=(.*)$/\1/p" "$DOCKERFILE" | head -1; }
ELIXIR_PIN="${ELIXIR_VERSION:-$(dockerfile_arg ELIXIR_VERSION)}"
OTP_PIN="${OTP_VERSION:-$(dockerfile_arg OTP_VERSION)}"
if [ -z "$ELIXIR_PIN" ] || [ -z "$OTP_PIN" ]; then
  fail "could not read ELIXIR_VERSION/OTP_VERSION from $DOCKERFILE (set ELIXIR_VERSION/OTP_VERSION)"
fi
# `elixir: "~> X.Y"` in mix.exs, and the -otp-NN suffix .tool-versions wants.
ELIXIR_REQ="$(printf '%s' "$ELIXIR_PIN" | cut -d. -f1,2)"
OTP_MAJOR="$(printf '%s' "$OTP_PIN" | cut -d. -f1)"

log "scaffolding Elixir $KIND '$APP_NAME' ($APP_MODULE) in $APP_DIR — elixir $ELIXIR_PIN / otp $OTP_PIN"
mkdir -p "$APP_DIR/lib/$APP_NAME" "$APP_DIR/test/$APP_NAME"

# ---- toolchain + tooling files ---------------------------------------------------
# CI reads this file directly (erlef/setup-beam's version-file), so bumping the
# toolchain is a commit to the project, never an edit to the workflow.
cat > "$APP_DIR/.tool-versions" <<EOF
elixir $ELIXIR_PIN-otp-$OTP_MAJOR
erlang $OTP_PIN
EOF

printf '%s\n' "$APP_NAME" > "$APP_DIR/.app-name"

cat > "$APP_DIR/.formatter.exs" <<'EOF'
[
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"]
]
EOF

{
  cat <<'EOF'
/_build/
/cover/
/deps/
/doc/
/.fetch
erl_crash.dump
*.ez
*.beam
/.elixir_ls/
.env
EOF
  # The built escript lands in the project root under the app's own name; it is
  # a build artifact, not source.
  [ "$KIND" = escript ] && printf '/%s\n' "$APP_NAME"
} > "$APP_DIR/.gitignore"

# ---- mix.exs ---------------------------------------------------------------------
{
  cat <<EOF
defmodule $APP_MODULE.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :$APP_NAME,
      version: @version,
      elixir: "~> $ELIXIR_REQ",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
EOF
  [ "$KIND" = escript ] && cat <<EOF
      # \`mix escript.build\` writes ./$APP_NAME — one file, runnable anywhere an
      # \`escript\` (i.e. an Erlang runtime) is installed. CI builds it on every
      # push and keeps it as a build artifact.
      escript: [main_module: $APP_MODULE.CLI],
EOF
  cat <<'EOF'
      # Everything below is metadata only — it costs nothing until there is
      # something to publish, and having it here means publishing is a
      # `mix hex.publish` away rather than a mix.exs rewrite.
      description: description(),
      package: package()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      # {:dep_from_hexpm, "~> 0.3.0"}
    ]
  end

  defp description do
EOF
  printf '    "TODO: one sentence describing %s."\n' "$APP_NAME"
  cat <<'EOF'
  end

  # Fill in :licenses and :links, then `mix hex.publish`.
  defp package do
    [
      licenses: [],
      links: %{}
    ]
  end
end
EOF
} > "$APP_DIR/mix.exs"

# ---- lib + test ------------------------------------------------------------------
cat > "$APP_DIR/lib/$APP_NAME.ex" <<EOF
defmodule $APP_MODULE do
  @moduledoc """
  $APP_MODULE — replace this with what the $KIND actually does.
  """

  @doc """
  A placeholder so the project compiles, runs and has something to test.

      iex> $APP_MODULE.hello()
      :world

  """
  @spec hello() :: :world
  def hello, do: :world
end
EOF

cat > "$APP_DIR/test/test_helper.exs" <<'EOF'
ExUnit.start()
EOF

cat > "$APP_DIR/test/${APP_NAME}_test.exs" <<EOF
defmodule ${APP_MODULE}Test do
  use ExUnit.Case, async: true
  doctest $APP_MODULE

  test "hello/0 answers" do
    assert $APP_MODULE.hello() == :world
  end
end
EOF

if [ "$KIND" = escript ]; then
  cat > "$APP_DIR/lib/$APP_NAME/cli.ex" <<EOF
defmodule $APP_MODULE.CLI do
  @moduledoc """
  Command-line entry point for \`$APP_NAME\`, reached through the escript
  \`mix escript.build\` produces.
  """

  @version Mix.Project.config()[:version]

  @doc """
  The escript's entry point. Prints what \`run/1\` returns and exits with its
  status — every decision worth testing lives in \`run/1\`, which returns
  instead of halting.
  """
  @spec main([String.t()]) :: :ok
  def main(argv) do
    {output, status} = run(argv)
    device = if status == 0, do: :stdio, else: :stderr
    IO.puts(device, output)
    if status != 0, do: System.halt(status)
    :ok
  end

  @doc """
  Parses \`argv\` and returns \`{output, exit_status}\`. Pure: it prints
  nothing and halts nothing, so tests can call it directly.
  """
  @spec run([String.t()]) :: {String.t(), non_neg_integer()}
  def run(argv) do
    case OptionParser.parse(argv,
           strict: [help: :boolean, version: :boolean],
           aliases: [h: :help, v: :version]
         ) do
      {[help: true], _, _} ->
        {usage(), 0}

      {[version: true], _, _} ->
        {"$APP_NAME #{@version}", 0}

      {_, [], []} ->
        {usage(), 0}

      {_, args, []} ->
        {greet(args), 0}

      {_, _, invalid} ->
        {"unknown option: #{Enum.map_join(invalid, ", ", &elem(&1, 0))}\\n\\n#{usage()}", 2}
    end
  end

  defp greet(args), do: "#{$APP_MODULE.hello()}: #{Enum.join(args, " ")}"

  defp usage do
    """
    $APP_NAME #{@version}

    Usage:
      $APP_NAME [options] [args...]

    Options:
      -h, --help     print this message
      -v, --version  print the version
    """
    |> String.trim_trailing()
  end
end
EOF

  cat > "$APP_DIR/test/$APP_NAME/cli_test.exs" <<EOF
defmodule $APP_MODULE.CLITest do
  use ExUnit.Case, async: true

  alias $APP_MODULE.CLI

  test "--help exits 0 and explains itself" do
    assert {output, 0} = CLI.run(["--help"])
    assert output =~ "Usage:"
  end

  test "--version prints the version from mix.exs" do
    assert {output, 0} = CLI.run(["--version"])
    assert output =~ "$APP_NAME"
  end

  test "no arguments is not an error" do
    assert {_, 0} = CLI.run([])
  end

  test "an unknown option exits non-zero and says which" do
    assert {output, 2} = CLI.run(["--nope"])
    assert output =~ "--nope"
  end

  test "arguments reach the app" do
    assert {output, 0} = CLI.run(["hi", "there"])
    assert output =~ "hi there"
  end
end
EOF
fi

# ---- README ----------------------------------------------------------------------
{
  cat <<EOF
# $APP_NAME

TODO: one sentence describing $APP_NAME.

## Develop

    mix deps.get
    mix test

EOF
  if [ "$KIND" = escript ]; then
    cat <<EOF
## Build the executable

    mix escript.build
    ./$APP_NAME --help

The escript is a single file. It needs an Erlang runtime on the machine that
runs it, and nothing else.
EOF
  else
    cat <<EOF
## Publish

Fill in \`:licenses\` and \`:links\` in \`mix.exs\`, then:

    mix hex.publish
EOF
  fi
  cat <<EOF

## Pipeline

Every push runs \`.github/workflows/ci.yml\` (or \`.gitea/workflows/ci.yml\`):
format check, compile with warnings as errors, and the test suite.

This project provisions no infrastructure — no droplet, no DNS, no database.
It was created with \`bootstrap.sh --$( [ "$KIND" = escript ] && printf cli || printf no-droplet )\`.

The BEAM versions are pinned in \`.tool-versions\`, which CI reads directly.
EOF
} > "$APP_DIR/README.md"

log "scaffolded $APP_DIR ($KIND): mix.exs, lib/, test/, .tool-versions, README.md"
