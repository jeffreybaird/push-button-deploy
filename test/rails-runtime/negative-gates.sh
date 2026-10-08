#!/usr/bin/env bash
# Run inside a Ruby environment with generated app dependencies installed.
# Fixture mutations are confined to a temporary copy, never the supplied app.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="${1:?generated application directory required}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp -R "$APP" "$WORK/app"
cd "$WORK/app"
export RAILS_ENV=test
unset DATABASE_PATH DATABASE_URL PRIMARY_DATABASE_URL
expect_failure() {
  local status=0
  "$@" > "$WORK/output" 2>&1 || status=$?
  [ "$status" -ne 0 ] || { echo "negative gate unexpectedly passed: $*" >&2; exit 1; }
  cat "$WORK/output"
}
bundle exec rails db:prepare
cp "$ROOT/test/fixtures/rails/negative/failing_spec.rb" spec/requests/failing_spec.rb
expect_failure bundle exec rspec spec/requests/failing_spec.rb
grep -q '1 failure' "$WORK/output"
rm spec/requests/failing_spec.rb
cp "$ROOT/test/fixtures/rails/negative/undefined.feature" features/undefined.feature
expect_failure bundle exec cucumber --strict features/undefined.feature
grep -qi undefined "$WORK/output"
rm features/undefined.feature
cp "$ROOT/test/fixtures/rails/negative/pending.feature" features/pending.feature
cp "$ROOT/test/fixtures/rails/negative/pending_steps.rb" features/step_definitions/pending_steps.rb
expect_failure bundle exec cucumber --strict features/pending.feature
grep -qi pending "$WORK/output"
rm features/pending.feature features/step_definitions/pending_steps.rb
cp "$ROOT/test/fixtures/rails/negative/lint.rb" app/lint.rb
expect_failure bundle exec rubocop app/lint.rb
grep -q 'Layout/SpaceAroundOperators' "$WORK/output"
rm app/lint.rb
rm -rf coverage
expect_failure bundle exec ruby script/coverage.rb
grep -q 'Both fresh RSpec and Cucumber coverage results are required' "$WORK/output"
# A single missing suite must fail even when the other result is valid.
bundle exec rspec
expect_failure bundle exec ruby script/coverage.rb
grep -q 'Both fresh RSpec and Cucumber coverage results are required' "$WORK/output"
rm -rf coverage
# Unloaded source must still count against coverage; no require added for it.
mkdir -p lib
cp "$ROOT/test/fixtures/rails/negative/uncovered.rb" lib/uncovered.rb
bundle exec rspec
bundle exec cucumber --strict
expect_failure bundle exec ruby script/coverage.rb
grep -qi 'coverage.*below\|below.*coverage' "$WORK/output"
echo 'RSpec, strict Cucumber, RuboCop, missing coverage and uncovered-source negative gates passed'
