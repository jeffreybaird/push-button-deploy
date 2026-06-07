#!/usr/bin/env bash
#
# ensure-release-task.sh — guarantee lib/<app>/release.ex exposes migrate/0 via
# Ecto.Migrator, with the module named after the app's actual base module.
#
# Production runs the release without Mix, so migrations run through this module:
#   bin/<app> eval "<Module>.Release.migrate()"   (story 5.3)
# `mix phx.gen.release` normally creates it; this generates it when absent
# (bootstrap, story 6.2) and refuses to clobber a non-compliant existing file.
#
# Usage:
#   scripts/ensure-release-task.sh [app_dir]            # generate if missing + verify
#   scripts/ensure-release-task.sh --check [app_dir]    # verify only, no writes
#
# Portable: BSD/macOS grep/sed.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=app-meta.sh
. "$HERE/app-meta.sh"

CHECK_ONLY=0
if [ "${1:-}" = "--check" ]; then CHECK_ONLY=1; shift; fi
APP_DIR="${1:-.}"

APP="$(app_name "$APP_DIR")"
MOD="$(app_module "$APP_DIR")"
REL="$APP_DIR/lib/$APP/release.ex"

verify() {
  if [ -f "$REL" ] \
     && grep -Eq "^defmodule[[:space:]]+${MOD}\.Release[[:space:]]+do" "$REL" \
     && grep -Eq '^[[:space:]]*def[[:space:]]+migrate\b' "$REL" \
     && grep -q 'Ecto.Migrator' "$REL"; then
    echo "OK: $REL defines ${MOD}.Release.migrate/0 via Ecto.Migrator."
    return 0
  fi
  echo "FAIL: $REL must define ${MOD}.Release.migrate/0 using Ecto.Migrator." >&2
  [ -f "$REL" ] && echo "(file exists but is non-compliant — not overwriting)" >&2
  [ "$CHECK_ONLY" -eq 1 ] && echo "Run: scripts/ensure-release-task.sh $APP_DIR" >&2
  exit 1
}

if [ "$CHECK_ONLY" -eq 1 ]; then
  verify
fi

# Compliant already, or present-but-wrong (refuse to clobber) -> verify decides.
if [ -f "$REL" ]; then
  verify
fi

mkdir -p "$APP_DIR/lib/$APP"
cat > "$REL" <<EOF
defmodule ${MOD}.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
  @app :${APP}

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
EOF

echo "Generated $REL (${MOD}.Release.migrate/0)."
verify
