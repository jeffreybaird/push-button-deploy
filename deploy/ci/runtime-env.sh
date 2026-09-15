#!/usr/bin/env bash
# Runner-side runtime configuration writer. Values arrive through the environment,
# never interpolated into shell source. APP_ENV is appended verbatim as before.
set -euo pipefail

write_runtime_env() { # $1 backend (postgres/sqlite), $2 environment (production/staging), $3 destination
  local backend="$1" environment="$2" destination="$3" key
  case "$backend" in postgres|sqlite) ;; *) echo "unknown backend: $backend" >&2; return 1 ;; esac
  case "$environment" in production|staging) ;; *) echo "unknown environment: $environment" >&2; return 1 ;; esac
  (
    umask 077
    # Redirection alone does not tighten permissions on a file left by a prior run.
    : > "$destination"
    chmod 600 "$destination"
    for key in IMAGE DOMAIN APP_SLUG; do
      printf '%s=%s\n' "$key" "${!key:-}"
    done > "$destination"
    if [ "$backend" = postgres ]; then
      printf 'DATABASE_URL=%s\n' "${DATABASE_URL:-}" >> "$destination"
    fi
    printf 'SECRET_KEY_BASE=%s\n' "${SECRET_KEY_BASE:-}" >> "$destination"
    if [ "$backend" = sqlite ]; then
      printf 'DATABASE_PATH=%s\n' "${DATABASE_PATH:-}" >> "$destination"
      if [ "$environment" = production ]; then
        for key in LITESTREAM_ACCESS_KEY_ID LITESTREAM_SECRET_ACCESS_KEY \
                   BACKUP_BUCKET BACKUP_ENDPOINT BACKUP_REGION BACKUP_PATH; do
          printf '%s=%s\n' "$key" "${!key:-}"
        done >> "$destination"
      fi
    fi
    printf '%s\n' "${APP_ENV:-}" >> "$destination"
    if [ "$environment" = staging ] && [ "$backend" = postgres ]; then
      grep -q '^DATABASE_URL=ecto://' "$destination" || {
        echo 'STAGING_DATABASE_URL is missing; re-run bootstrap to configure the staging database.' >&2
        exit 1
      }
    fi
  )
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  write_runtime_env "${1:?backend required}" "${2:?environment required}" "${3:-.env}"
fi
