#!/usr/bin/env bash
#
# lib/pbd/common.sh — what every pbd subcommand needs before it can do anything:
# where the tool's files are, where the user's files go, and what is in the
# environment.
#
# Sourced by bin/pbd exactly once, BEFORE any command module. Nothing here
# resolves an app type, a framework or a provider — those read the environment
# this file loads, so they must come after it.
#
# THE SPLIT THIS FILE EXISTS FOR. Every one of these scripts used to compute a
# single $SCRIPT_DIR and use it for two unrelated jobs: finding the templates it
# ships (infra-*/, app/, deploy/, scripts/) and keeping the user's own files
# (.env, bootstrap.log, the cached Gitea admin token). That works when the tool
# IS a checkout you cd into. It does not survive being installed — a Homebrew
# prefix is not a place to write logs and secrets. So:
#
#   PBD_ROOT       read-only, ships with the tool: the templates and the library
#   PBD_STATE_DIR  writable, belongs to the user: logs and cached credentials
#   the env file   the user's configuration, found by search rather than assumed
#
# Portable: BSD/macOS bash 3.2, grep, sed.

# ---- version -------------------------------------------------------------------
# One source of truth, in a file a release process can bump without editing code.
pbd_version() {
  if [ -f "$PBD_ROOT/VERSION" ]; then tr -d '[:space:]' < "$PBD_ROOT/VERSION"
  else printf '0.0.0-dev'; fi
}

# ---- console -------------------------------------------------------------------
# Baseline reporting, available from the moment bin/pbd starts. Command modules
# redefine log/warn/fail afterwards with versions that also write their run
# transcript; anything printed before that (env-file resolution, an unknown
# subcommand) comes out through these.
pbd_ts()   { date +%H:%M:%S; }
log()      { printf '\033[32m==>\033[0m [%s] %s\n' "$(pbd_ts)" "$*"; }
warn()     { printf '\033[33m==> WARN\033[0m [%s] %s\n' "$(pbd_ts)" "$*" >&2; }
fail()     { printf '\033[31mpbd: %s\033[0m\n' "$*" >&2; exit 1; }
have()     { command -v "$1" >/dev/null 2>&1; }

# Exit 2 for a usage error, so a caller can tell "you typed it wrong" from "it
# ran and failed". The same contract the CLIs this tool scaffolds are held to.
# die_usage <usage_function> <message>
die_usage() {
  local usage_fn="$1"; shift
  printf 'pbd: %s\n\n' "$*" >&2
  # The caller names the usage to print — the top-level one, or the subcommand's,
  # whichever is the more useful thing to be looking at.
  "$usage_fn" >&2
  exit 2
}

# ---- where the tool is ---------------------------------------------------------
# PBD_ROOT is the directory the tool's own files live under. In a checkout that
# is the repo; installed, it is whatever prefix the tree was copied into. The
# LAYOUT IS THE SAME either way (bin/, lib/, scripts/, infra-*/, app/, deploy/),
# which is what lets one relative path serve both and keeps the Homebrew formula
# to a directory copy and a symlink.
#
# PBD_ROOT in the environment wins, for running a checkout's templates against an
# installed binary (or the reverse) without reinstalling either.
#
# pbd_resolve_root <root bin/pbd resolved for itself>
#
# bin/pbd does the symlink walk — it is the only file that can, since it has to
# find this one — and hands the answer here to be overridden and checked.
pbd_resolve_root() {
  if [ -n "${PBD_ROOT:-}" ]; then
    [ -d "$PBD_ROOT" ] || fail "PBD_ROOT is set to '$PBD_ROOT', which is not a directory"
    PBD_ROOT="$(cd "$PBD_ROOT" && pwd)"
  else
    PBD_ROOT="$1"
  fi

  # Fail here, with the reason, rather than three steps in on a missing template.
  [ -d "$PBD_ROOT/lib/pbd" ] && [ -d "$PBD_ROOT/scripts" ] \
    || fail "installation looks incomplete: '$PBD_ROOT' has no lib/pbd and scripts/ under it.
       Set PBD_ROOT to a push-button-deploy checkout, or reinstall."
  export PBD_ROOT
}

# ---- where the user's files go -------------------------------------------------
# Logs and cached credentials. XDG by default; PBD_STATE_DIR overrides it. Not
# under PBD_ROOT, which may be read-only and is shared between every project.
pbd_resolve_state_dir() {
  if [ -z "${PBD_STATE_DIR:-}" ]; then
    PBD_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/pbd"
  fi
  mkdir -p "$PBD_STATE_DIR" || fail "cannot create the state directory '$PBD_STATE_DIR' (override it with PBD_STATE_DIR)"
  export PBD_STATE_DIR
}

# pbd_state_file <name> [legacy_path]
#
# Absolute path to a file in the state directory. When a LEGACY path is given
# and holds the only copy, it is moved in first: a checkout that has been
# caching a Gitea admin token beside the script keeps that token instead of
# silently generating a second admin account.
pbd_state_file() {
  local legacy="${2:-}" dest="$PBD_STATE_DIR/$1"
  if [ -n "$legacy" ] && [ -f "$legacy" ] && [ ! -f "$dest" ]; then
    if cp "$legacy" "$dest" 2>/dev/null; then
      chmod 600 "$dest" 2>/dev/null || true
      warn "moved $legacy into $dest (state now lives outside the install)"
      rm -f "$legacy" 2>/dev/null || true
    fi
  fi
  printf '%s' "$dest"
}

# ---- configuration -------------------------------------------------------------
# The env file: the deploy's single source of truth (see .env.example). Searched
# for rather than assumed to sit beside the script, because installed there IS no
# "beside the script". First hit wins:
#
#   1. --env-file <path> / PBD_ENV_FILE   explicit; a missing one is an error,
#                                         never a silent fall-through
#   2. $XDG_CONFIG_HOME/pbd/env           where an installed pbd keeps it
#   3. $PBD_ROOT/.env                     a checkout's own .env, still honoured
#
# The CURRENT DIRECTORY is deliberately not searched: app directories carry their
# own unrelated .env files (the app's runtime config), and picking one of those
# up as the deploy's credentials would provision against the wrong account
# without saying so. Name it with --env-file when it is somewhere else.
pbd_env_file_path() {
  if [ -n "${PBD_ENV_FILE:-}" ]; then
    [ -f "$PBD_ENV_FILE" ] || fail "env file '$PBD_ENV_FILE' does not exist"
    printf '%s' "$PBD_ENV_FILE"; return 0
  fi
  local xdg="${XDG_CONFIG_HOME:-$HOME/.config}/pbd/env"
  if [ -f "$xdg" ];             then printf '%s' "$xdg";            return 0; fi
  if [ -f "$PBD_ROOT/.env" ];   then printf '%s' "$PBD_ROOT/.env";  return 0; fi
  return 0   # no file is fine: everything can come from the environment
}

# Load the env file, if there is one.
#
# PRECEDENCE: THE CALLING SHELL WINS. A value already set in the environment is
# restored after the file is sourced, so a per-run override does what it looks
# like it does:
#
#     DNS_ZONE=other.com pbd bootstrap ~/src/site
#
# This used to be the other way round — the file overrode the shell — which made
# per-run overrides silently impossible: the run above would provision against
# whatever the file said and report success, having built the wrong thing. An
# override that differs is announced rather than applied in silence.
#
# Shell-sourced, so $HOME etc. expand; `set -a` exports plain KEY=value lines (an
# `export ` prefix also works).
pbd_load_env() {
  PBD_ENV_FILE_LOADED="$(pbd_env_file_path)"
  export PBD_ENV_FILE_LOADED
  [ -n "$PBD_ENV_FILE_LOADED" ] || return 0

  local tmp k line was
  tmp="$(mktemp)"
  # Every KEY on a plain or `export `-prefixed assignment line.
  for k in $(sed -nE 's/^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=.*/\2/p' "$PBD_ENV_FILE_LOADED"); do
    # ${!k+x} is set only when the variable EXISTS in the environment, so an
    # explicit empty value still counts as "the caller said so".
    if [ -n "${!k+x}" ]; then printf '%s=%q\n' "$k" "${!k}" >> "$tmp"; fi
  done

  set -a
  # shellcheck disable=SC1090
  . "$PBD_ENV_FILE_LOADED"
  set +a

  # Re-apply what the caller set, and say so where the file disagreed. Still
  # inside `set -a`'s effect for these names: they were exported while sourcing.
  if [ -s "$tmp" ]; then
    while IFS= read -r line; do
      k="${line%%=*}"
      was="${!k}"
      eval "export $line"
      [ "$was" != "${!k}" ] && warn "$k: using '${!k}' from the environment, not '$was' from $PBD_ENV_FILE_LOADED"
    done < "$tmp"
  fi
  rm -f "$tmp"
}

# ---- app directories -----------------------------------------------------------
# Absolute path for a directory that may not exist yet (bootstrap generates it).
abs_dir() {
  if [ -d "$1" ]; then (cd "$1" && pwd); else
    case "$1" in
      /*) printf '%s\n' "$1" ;;
      *)  printf '%s/%s\n' "$PWD" "$1" ;;
    esac
  fi
}
