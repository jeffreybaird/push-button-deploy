# Testing and quality gates

Fresh scaffolds use RSpec for services and requests, Cucumber with Capybara's
Rack Test driver for user behavior, SimpleCov for coverage, RuboCop with Rails
and RSpec plugins for static analysis, and bundler-audit for dependency advisories.
No browser or JavaScript runtime is required by the generated feature.

Run `bin/check`. It forces the test environment, clears inherited database
connection overrides and stale coverage, prepares the database, then executes:

```sh
bundle exec rubocop
bundle exec rspec
bundle exec cucumber --strict
bundle exec ruby script/coverage.rb
bundle exec bundler-audit check --update
```

Every command must pass. The coverage gate collates exactly the two fresh suite
results and enforces **100% line and 100% branch coverage** across all Ruby files
in `app/` and `lib/`, including files neither suite loaded. Missing results fail.
Do not lower thresholds, exclude application files, ignore branches, suppress
cops, or reuse old results to get green. Undefined and pending Cucumber steps
fail strict execution. No examples is a failing RSpec run.

Before committing, safely autocorrect owned files with
`bundle exec rubocop --autocorrect <owned paths>`, then rerun `bin/check`.
Do not use unsafe autocorrection or change accepted tests outside their owner.
Follow the shared agent workflow for red, accepted tests, implementation, green
and independent review. Commit the lockfile and check current advisories.

Unit/service specs test successful persistence, every Result tag, pagination
bounds, archive visibility and atomic audit failure. Request specs cover actual
routing, strong parameters, HTTP status and rendering. Feature scenarios describe
business behavior in plain Gherkin and assert both visible results and durable
state. Use labels and stable `data-testid` hooks, not CSS presentation classes.

RSpec normally uses transactional cleanup. Commit-sensitive specs use explicit
nontransactional cleanup to prove outer commit/rollback timing. Cucumber uses
deletion before and after each real HTTP scenario so separate connections can
commit while scenarios remain isolated.
Never replace meaningful happy-path assertions with mocks that cannot detect a
broken implementation. Mock optional external clients at their own boundary;
ordinary tests must not contact real vendors.

Adopted applications keep their existing code. If no `bin/check` exists, generated
workflows explicitly run the legacy `rails db:prepare` and `rails test` gate.
Once `bin/check` is present, its failure (including missing execute permission)
is fatal; no fallback is allowed. Adopting this quality profile requires adding
its tools, tests and coverage configuration deliberately.

Every major user workflow needs a Cucumber happy path and meaningful failure
scenarios. When authentication and authorization are introduced, test denied
actions at request and service boundaries. When multi-tenancy is introduced,
each read and mutation needs isolation tests proving that another tenant's
records cannot be viewed or changed, including forged identifiers.

## Pull request evidence

Follow `.docs/agent-workflow.md#pull-request-test-evidence` for every PR. Include
the relevant Cucumber feature paths and scenario names with readable Gherkin,
scenario content or actual executed scenario output; names or links alone are
insufficient. Run `bundle exec rspec <relevant spec paths> --format documentation`
and include its actual command, output and results. Report failures, skipped and
pending examples honestly; never invent output. Use expandable details for long
output. Still run the full required `bin/check` gate and report its result.

Fresh Rails projects require both suites; missing mandatory tooling is a defect,
not `N/A`. Use `N/A` with a reason for unrelated ecosystems or changes. Adopted
applications keep their explicit legacy gate until they deliberately adopt this
profile; report that limitation and actual checks honestly. Do not bypass gates
or install an unrelated framework solely for reporting.
