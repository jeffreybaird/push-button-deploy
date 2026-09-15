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

# Validate the expected release entry point without changing the application.
validate_release_task() { # $1 release file, $2 base module
  local release_file="$1" module="$2"
  if [ -f "$release_file" ] \
     && awk -v expected="${module}.Release" '$1 == "defmodule" && $2 == expected && $3 == "do" { found = 1 } END { exit !found }' "$release_file" \
     && grep -Eq '^[[:space:]]*def[[:space:]]+migrate([[:space:]]|\(|,|$)' "$release_file" \
     && grep -q 'Ecto.Migrator' "$release_file"; then
    printf 'OK: %s defines %s.Release.migrate/0 via Ecto.Migrator.\n' "$release_file" "$module"
    return 0
  fi
  printf 'FAIL: %s must define %s.Release.migrate/0 using Ecto.Migrator.\n' "$release_file" "$module" >&2
  if [ -f "$release_file" ]; then
    printf '(file exists but is non-compliant — not overwriting)\n' >&2
  fi
  return 1
}

generate_release_task() { # $1 release file, $2 OTP app, $3 base module
  local release_file="$1" app="$2" module="$3"
  mkdir -p "$(dirname "$release_file")"
cat > "$release_file" <<EOF
defmodule ${module}.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
  @app :${app}

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

  printf 'Generated %s (%s.Release.migrate/0).\n' "$release_file" "$module"
}

main() {
  local check_only=0 app_dir app module release_file
  if [ "${1:-}" = --check ]; then check_only=1; shift; fi
  app_dir="${1:-.}"
  app="$(app_name "$app_dir")"
  module="$(app_module "$app_dir")"
  release_file="$app_dir/lib/$app/release.ex"

  if [ "$check_only" -eq 1 ] || [ -e "$release_file" ]; then
    validate_release_task "$release_file" "$module"
    return $?
  fi

  generate_release_task "$release_file" "$app" "$module"
  validate_release_task "$release_file" "$module"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
