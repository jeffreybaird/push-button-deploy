#!/usr/bin/env bash
# Claude Code cloud bootstrap — run by the SessionStart hook in
# .claude/settings.json, NOT by the environment's "Setup script" field.
#
# Cloud setup scripts (the UI field) run before the repository is cloned,
# so they can never reference checked-in files; SessionStart hooks run
# after the clone with $CLAUDE_PROJECT_DIR set. Leave the environment's
# Setup script field EMPTY and give the environment "Full" network access
# (or a Custom allowlist: elixir-lang.org, github.com,
# objects.githubusercontent.com, release-assets.githubusercontent.com,
# repo.hex.pm, builds.hex.pm, registry.npmjs.org, and for the Docker
# fallback: registry-1.docker.io, auth.docker.io, hub.docker.com,
# production.cloudflare.docker.com).
#
# The cloud egress proxy may scope GitHub to this repository only, which
# 403s the official installer's Elixir release download. When that
# happens the script falls back to pulling the exact hexpm/elixir
# builder image the Dockerfile pins (Docker Hub is not repo-scoped) and
# copying the toolchain out of it.
#
# Runs on every cloud session: Postgres restarts each time (the snapshot
# caches the filesystem, not processes); the toolchain/deps/DB bootstrap
# runs once and is skipped afterwards via a stamp file. Local sessions
# exit immediately. SQLite-backed apps (no :postgrex dep) skip the
# Postgres sections entirely.
#
# Elixir/OTP versions come from the Dockerfile ARGs — the same source of
# truth .github/workflows/deploy.yml uses.
set -euo pipefail

[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || exit 0
cd "${CLAUDE_PROJECT_DIR:-.}"

LOG=/tmp/my_app-cloud-setup.log
echo "cloud bootstrap running; full log: $LOG"
exec >>"$LOG" 2>&1

USES_POSTGRES=false
grep -q '{:postgrex' mix.exs && USES_POSTGRES=true

if $USES_POSTGRES; then
  echo "==> Starting PostgreSQL"
  if ! command -v pg_lsclusters >/dev/null; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq && apt-get install -y -qq postgresql
  fi
  if ! pg_lsclusters | grep -q .; then
    PG_VER="$(ls /usr/lib/postgresql | sort -n | tail -1)"
    pg_createcluster "$PG_VER" main
  fi
  service postgresql start || true
  for _ in $(seq 1 30); do
    pg_isready -q && break
    sleep 1
  done
  pg_isready -q
fi

STAMP="$HOME/.cache/my_app-cloud-bootstrap"
if [ -f "$STAMP" ]; then
  echo "==> Bootstrap already done ($STAMP)."
  exit 0
fi

if $USES_POSTGRES; then
  # config/dev.exs and config/test.exs connect as postgres/postgres over TCP.
  su - postgres -c "psql -tAc \"ALTER USER postgres PASSWORD 'postgres';\"" >/dev/null
fi

echo "==> Parsing Elixir/OTP pins from Dockerfile"
ELIXIR_VERSION=$(grep -E '^ARG ELIXIR_VERSION=' Dockerfile | head -1 | cut -d= -f2)
OTP_VERSION=$(grep -E '^ARG OTP_VERSION=' Dockerfile | head -1 | cut -d= -f2)
if [ -z "$ELIXIR_VERSION" ] || [ -z "$OTP_VERSION" ]; then
  echo "could not parse ELIXIR_VERSION/OTP_VERSION ARGs from Dockerfile" >&2
  exit 1
fi
echo "    elixir=$ELIXIR_VERSION otp=$OTP_VERSION"

# Fast path: the official installer's precompiled builds. Claude runs
# commands in non-interactive shells that skip profile files, so the
# toolchain is exposed via /usr/local instead of PATH exports.
install_via_official_installer() {
  curl -fsSO https://elixir-lang.org/install.sh &&
    sh install.sh "elixir@$ELIXIR_VERSION" "otp@$OTP_VERSION" &&
    rm -f install.sh &&
    ln -sf "$HOME/.elixir-install/installs/otp/$OTP_VERSION/bin/"* /usr/local/bin/ &&
    ln -sf "$HOME/.elixir-install/installs/elixir/$ELIXIR_VERSION-otp-${OTP_VERSION%%.*}/bin/"* /usr/local/bin/
}

# Fallback: copy the toolchain out of the exact builder image the
# Dockerfile pins. Debian bookworm binaries run fine on the Ubuntu 24.04
# host (older glibc than the host's).
install_via_builder_image() {
  local debian_version image cid
  debian_version=$(grep -E '^ARG DEBIAN_VERSION=' Dockerfile | head -1 | cut -d= -f2)
  image="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${debian_version}"
  echo "==> Pulling $image"

  if ! docker info >/dev/null 2>&1; then
    (service docker start >/dev/null 2>&1 || dockerd >/var/log/dockerd.log 2>&1) &
    for _ in $(seq 1 30); do
      docker info >/dev/null 2>&1 && break
      sleep 1
    done
  fi

  docker pull "$image"
  cid=$(docker create "$image")
  rm -rf /tmp/hexpm-toolchain
  docker cp "$cid:/usr/local" /tmp/hexpm-toolchain
  docker rm "$cid" >/dev/null
  cp -a /tmp/hexpm-toolchain/lib/. /usr/local/lib/
  cp -a /tmp/hexpm-toolchain/bin/. /usr/local/bin/
  rm -rf /tmp/hexpm-toolchain
}

if ! command -v elixir >/dev/null || ! elixir --version | grep -q "$ELIXIR_VERSION"; then
  echo "==> Installing Erlang/OTP $OTP_VERSION + Elixir $ELIXIR_VERSION (precompiled)"
  if ! install_via_official_installer; then
    echo "==> Official installer blocked (repo-scoped GitHub egress?); using Docker fallback"
    install_via_builder_image
  fi
fi
elixir --version

# Erlang warns without a UTF-8 locale; C.UTF-8 needs no locale-gen.
grep -q "^LANG=" /etc/environment 2>/dev/null || echo "LANG=C.UTF-8" >>/etc/environment
export LANG=C.UTF-8

echo "==> Installing Hex and Rebar"
mix local.hex --force
mix local.rebar --force

echo "==> Fetching deps, building app + assets, creating dev DB (with seeds)"
mix setup

echo "==> Preparing the test environment"
MIX_ENV=test mix do ecto.create --quiet, ecto.migrate --quiet, compile

mkdir -p "$(dirname "$STAMP")"
touch "$STAMP"
echo "==> Bootstrap complete. Verify with: mix test"
