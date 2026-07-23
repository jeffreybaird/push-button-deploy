#!/usr/bin/env bash
# Claude Code cloud bootstrap — run by the SessionStart hook in
# .claude/settings.json, NOT by the environment's "Setup script" field.
#
# Cloud setup scripts (the UI field) run before the repository is cloned, so
# they can never reference checked-in files; SessionStart hooks run after the
# clone with $CLAUDE_PROJECT_DIR set. Leave the environment's Setup script field
# EMPTY and give the environment "Full" network access (or a Custom allowlist:
# github.com, rubygems.org, index.rubygems.org, objects.githubusercontent.com,
# and — if the pinned Ruby must be installed — cache.ruby-lang.org).
#
# Runs on every cloud session; the heavy work (gem install + DB migrate) runs
# once and is skipped afterward via a stamp file. Local sessions exit
# immediately.
#
# The Ruby version comes from .ruby-version — the same source of truth the
# Dockerfile's RUBY_VERSION ARG and CI's ruby-version-file use. This SQLite app
# has no external database service to start.
set -euo pipefail

[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || exit 0
cd "${CLAUDE_PROJECT_DIR:-.}"

LOG=/tmp/my_app-cloud-setup.log
echo "cloud bootstrap running; full log: $LOG"
exec >>"$LOG" 2>&1

RUBY_WANT="$(tr -d '[:space:]' < .ruby-version 2>/dev/null || true)"
echo "==> wanted Ruby: ${RUBY_WANT:-unspecified}"

# Ensure a matching Ruby is on PATH. Prefer a version manager if one is present
# (mise/rbenv/asdf are common on cloud images); otherwise fall back to whatever
# `ruby` is installed and let bundler report a mismatch loudly.
ensure_ruby() {
  [ -n "$RUBY_WANT" ] || return 0
  if command -v ruby >/dev/null && ruby -e 'exit(RUBY_VERSION == ARGV[0])' "$RUBY_WANT"; then
    return 0
  fi
  if command -v mise >/dev/null; then
    mise install "ruby@${RUBY_WANT}" && mise use -g "ruby@${RUBY_WANT}"
    eval "$(mise activate bash 2>/dev/null || true)"
  elif command -v rbenv >/dev/null; then
    rbenv install -s "$RUBY_WANT" && rbenv global "$RUBY_WANT"
    eval "$(rbenv init - 2>/dev/null || true)"
  elif command -v asdf >/dev/null; then
    asdf plugin add ruby 2>/dev/null || true
    asdf install ruby "$RUBY_WANT" && asdf global ruby "$RUBY_WANT"
  else
    echo "!! no version manager and system Ruby != ${RUBY_WANT}; continuing with $(ruby -v 2>/dev/null || echo 'no ruby')"
  fi
}
ensure_ruby
ruby -v || { echo "no Ruby available" >&2; exit 1; }

echo "==> Ensuring Bundler"
gem install bundler --conservative >/dev/null 2>&1 || true

STAMP="$HOME/.cache/my_app-cloud-bootstrap"
if [ -f "$STAMP" ]; then
  echo "==> Bootstrap already done ($STAMP); refreshing deps only"
  bundle check >/dev/null 2>&1 || bundle install
  exit 0
fi

echo "==> Installing gems"
bundle install

echo "==> Creating + migrating the development database"
bundle exec rake db:migrate

echo "==> Preparing the test database"
RACK_ENV=test bundle exec rake db:migrate

mkdir -p "$(dirname "$STAMP")"
touch "$STAMP"
echo "==> Bootstrap complete. Verify with: bundle exec rspec"
