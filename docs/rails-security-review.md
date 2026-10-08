# Rails support security review

Reviewed 2026-10-07. This covers the scaffold, deployment integration, and
identified Ruby advisories. It is not a comprehensive infrastructure or production
exposure assessment.

## Review and audit scope

The repository has no root application dependency lockfile or repository-wide
dependency audit command. Initial inspection (`command -v bundle-audit` and
`ruby --version`) found no auditor and macOS Ruby 2.6.10. That interpreter is used
by the offline structural tests; it cannot validate Rails 8.1 execution.

The parent session obtained a Ruby 3.3.12 Docker runtime and installed
bundler-audit 0.9.3 for isolated application dependency validation. Its base image
reports erb 4.0.3.1, net-imap 0.4.25, rexml 3.4.4, and resolv 0.3.1. The latter
still needs a gem upgrade despite the Ruby patch release.

The generated Rails Gemfile was resolved with `bundle lock`, then checked using
`bundle-audit check --update` in that Docker runtime. The final check exited 0
with no reported vulnerabilities. ruby-advisory-db revision
`b6604fa6b54cb6e9a140e3a12d1f1d15b695330c` contained 1,261 advisories and reported
an update time of 2026-10-07 20:03:30 -0400. The resolved versions included Rails
8.1.4, Puma 7.2.1, sqlite3 2.9.6, erb 6.0.7, resolv 0.3.2, and
rails-html-sanitizer 1.7.1. The final log is
`/tmp/pbd-rails-audit/output-final.log`; the lockfile is in the same temporary
directory. This result covers that resolved application dependency set, not
future resolutions or container OS packages.

The same fresh-lockfile audit was run for newly generated Sinatra and Ruby CLI
apps. The initial Sinatra resolution reported the two Puma findings below;
after updating its Puma constraint to `~> 7.2.1`, the final audit reported no
vulnerabilities. The Ruby CLI audit likewise reported none. Logs are
`/tmp/pbd-rails-audit/sinatra-audit-final.log` and
`/tmp/pbd-rails-audit/ruby-cli-audit.log`, using the same advisory database
revision. These checks do not scan deployed copies of those applications.

## Findings and compatible fixes

The existing Sinatra and Ruby CLI scaffolds and Ruby Dockerfile previously
defaulted to Ruby 3.3.6. New scaffolds now use 3.3.12, including Rails. This changes
future generation defaults; it does not update already generated apps or override
an explicit `RUBY_VERSION`/application `.ruby-version`. The exact default gem
versions inside previously deployed 3.3.6 images were not inspected.

| Advisory | Affected dependency and versions | Patched versions / treatment | Exposure conditions |
| --- | --- | --- | --- |
| [CVE-2026-47736 / GHSA-qpgp-93vx-g8v8](https://github.com/puma/puma/security/advisories/GHSA-qpgp-93vx-g8v8) and [CVE-2026-47737 / GHSA-2vqw-3mp8-cgmx](https://github.com/puma/puma/security/advisories/GHSA-2vqw-3mp8-cgmx) | Fresh audit of the pre-existing Sinatra constraint resolved Puma 6.6.1, which is affected. Rails resolved patched 7.2.1 | Puma 7.2.1 or >=8.0.2; Rails and Sinatra constrain Puma to `~> 7.2.1` | Non-default PROXY protocol v1 parsing enables memory exhaustion or repeated-header abuse. Generated Puma configurations do not enable it; user-modified configurations may. |
| [CVE-2026-66066 / GHSA-xr9x-r78c-5hrm](https://github.com/rails/rails/security/advisories/GHSA-xr9x-r78c-5hrm) | Active Storage 8.1 before 8.1.3.1; no Rails dependency existed in this utility before this change | New Rails constraint starts at 8.1.4 | Crafted libvips image variants can expose files or execute code. The minimal scaffold does not enable Active Storage. Existing apps may. |
| [CVE-2026-73648 / GHSA-cj75-f6xr-r4g7](https://github.com/rails/rails-html-sanitizer/security/advisories/GHSA-cj75-f6xr-r4g7) | rails-html-sanitizer >=1.0.3, <1.7.1; generated dependency, previously uninstalled here | New Rails constraint requires >=1.7.1 | Custom SVG `use`/`feImage` allowlists permit XSS; default configuration is not affected. |
| [CVE-2026-80212 and CVE-2026-80213](https://www.ruby-lang.org/en/news/2026/08/27/multiple-vulnerabilities-in-resolv/) | resolv <=0.3.1 and 0.4.0–0.7.1; Docker Ruby 3.3.12 includes 0.3.1 | 0.3.2 or 0.7.2; generated Rails/Sinatra Gemfiles and Ruby CLI gemspec use `~> 0.3.2`, excluding the affected 0.4–0.7.1 releases | Malicious DNS replies can exhaust memory; overlong hostnames can bypass hostname validation. Requires `Resolv`, `resolv-replace`, or a dependency using them. Ordinary OS-backed socket resolution is not affected. |
| [CVE-2026-41316](https://www.ruby-lang.org/en/news/2026/04/21/erb-cve-2026-41316/) | erb <=6.0.3, excluding patched backports; Ruby 3.3.12 image has patched 4.0.3.1 | 4.0.3.1, 4.0.4.1, 6.0.1.1 or >=6.0.4; patched Ruby default and Rails gem floor | Untrusted `Marshal.load` with ERB and ActiveSupport loaded can execute code. No such call is generated. |
| [CVE-2026-27820](https://www.ruby-lang.org/en/news/2026/03/05/buffer-overflow-zlib-cve-2026-27820/) | zlib <=3.2.2, excluding patched backports; old 3.3.6 default predates fix | 3.0.1, 3.1.2 or >=3.2.3; Ruby 3.3.11 included the fix, retained by 3.3.12 | `Zlib::GzipReader` buffer manipulation can corrupt memory. Generated-app reachability was not exhaustively established. |
| [CVE-2025-61594](https://www.ruby-lang.org/en/news/2025/10/07/uri-cve-2025-61594/) and [CVE-2025-27221](https://www.ruby-lang.org/en/news/2025/02/26/security-advisories/) | URI <0.12.5, 0.13.0–0.13.2, 1.0.0–1.0.3 for the later bypass; old Ruby 3.3.6 predates fixes | 0.12.5, 0.13.3 or >=1.0.4; Ruby 3.3.10 updated URI, retained by 3.3.12 | Combining URLs containing credentials with attacker-controlled destinations may leak userinfo. |
| [CVE-2025-24294](https://www.ruby-lang.org/en/news/2025/07/08/dos-resolv-cve-2025-24294/) | resolv 0.3.0 on Ruby 3.3; old default predates fix | Ruby 3.3.9 updated resolv; the newer 0.3.2/0.7.2 floor also addresses August 2026 findings | Crafted compressed DNS names cause CPU exhaustion. |
| [CVE-2025-27219](https://www.ruby-lang.org/en/news/2025/02/26/security-advisories/) | cgi <=0.3.5, 0.3.6, 0.4.0–0.4.1; old default predates fix | 0.3.5.1, 0.3.7 or >=0.4.2; updated Ruby defaults | Crafted `CGI::Cookie.parse` input causes denial of service. Related CVE-2025-27220 affects Ruby 3.1/3.2, not the selected 3.3 runtime. |
| [CVE-2026-42245, CVE-2026-42246, CVE-2026-42256, CVE-2026-42257, CVE-2026-42258, CVE-2026-47240, CVE-2026-47241, CVE-2026-47242](https://www.ruby-lang.org/en/news/2026/07/16/ruby-3-3-12-released/) | Earlier net-imap versions; the inspected Ruby 3.3.12 image includes 0.4.25 | net-imap 0.4.25 includes all listed fixes | IMAP command input, hostile server replies, or authentication/TLS interactions. The generated minimal app does not configure IMAP. Individual advisory ranges and previously deployed versions were not exhaustively inventoried. |

No Rails feature or dependency constraint was removed to suppress a finding.
Existing user applications need their own resolved-lockfile audit, including
their optional components and runtime overrides.

## Remaining coverage limits

Terraform provider locks, their transitive binaries, Litestream/Caddy images,
Linux OS packages, cloud accounts and existing deployments were not
comprehensively scanned. Their advisory status remains uncertain. The prior
[workflow security review](agent-workflow-security-review.md) records host Python
findings and remediation; those do not establish other runtimes are clean.

The source/test ownership audit contains historical ambiguous entries. Such
entries record overlapping calls, not proof of unauthorized changes. Accepted
Rails test hashes were checked again during final review: all 11 files matched
the reviewed contract. Fixture corrections added the Rails template to isolated
bundles, checked managed guidance in both native entrypoints, and explicitly read
UTF-8 Dockerfile text; they did not remove behavior assertions.

`bash test/run.sh` passed all 21 suites and shell syntax checks. The final Rails
Docker validation, on native ARM64, ran production `db:prepare` twice as UID
65534, verified SQLite WAL mode, passed the generated integration test, and
received HTTP 200 from the running Puma `/health` endpoint. These checks do not
establish an amd64 production deployment, live cloud-provider compatibility, or
backup restore behavior against real Spaces storage.

The patched Sinatra scaffold also completed migrations, passed all five RSpec
examples, and returned HTTP 200 with `{"status":"ok"}` from Puma 7.2.1 at `/up`.
This verifies the exercised configuration remains compatible after its security
upgrade; custom applications and non-default Puma configurations need their own
upgrade verification.

## Rails conventions and quality tooling follow-up

The expanded Rails scaffold adds runtime `dry-monads` and development/test
dependencies for RSpec, Cucumber, Capybara, Database Cleaner, SimpleCov, RuboCop
and bundler-audit. A fresh complete lockfile, including those groups, was resolved
in an isolated Ruby 3.3.12 Docker environment using `bundle lock`, then checked
with `bundle-audit check --update` (bundler-audit 0.9.3). The check exited 0 with
no reported vulnerabilities. The advisory database remained revision
`b6604fa6b54cb6e9a140e3a12d1f1d15b695330c`, containing 1,261 advisories and last
updated 2026-10-07 20:03:30 -0400. Evidence is in
`/tmp/pbd-rails-conventions-audit/audit.log` and its adjacent `Gemfile.lock`.

The resolved tooling versions were rspec-rails 8.0.4, cucumber-rails 4.1.0,
Cucumber 11.1.1, Capybara 3.40.0, SimpleCov 1.3.2, RuboCop 1.91.0,
rubocop-rails 2.38.0, rubocop-rspec 3.10.2, dry-monads 1.11.0 and
database_cleaner-active_record 2.2.2. Rails 8.1.4, Puma 7.2.1, resolv 0.3.2,
erb 6.0.7 and rails-html-sanitizer 1.7.1 retain the fixes discussed above.
This is a check of the resolved gem set against the available current database;
it does not establish that unknown vulnerabilities, container OS packages or
existing deployed applications are clean.

The Notes example stores a minimal durable audit record in the same transaction
as each mutation. Notification payloads contain only record IDs and publish
after the enclosing transaction commits. Those in-process notifications are
not a durable delivery mechanism. The example has no authentication or tenant
isolation and requires application-specific access control before use for
private data. Test runners clear `DATABASE_PATH`, `DATABASE_URL` and
`PRIMARY_DATABASE_URL` and select the test environment before preparing or
cleaning databases, preventing inherited production connection settings from
redirecting the generated test suite.

Independent privacy review found that Rails' default request parameter logging
would expose note titles and credential fields even though the durable audit
payload was minimal. The scaffold now configures Rails parameter filtering for
titles and common credential keys. Four request/privacy examples demonstrate
redaction, retained harmless metadata and unchanged persistence of the original
title. Filtering does not sanitize arbitrary custom logging calls; future code
must preserve the logging guidance.

The final generated application's real quality gate passed 34 Ruby files with
RuboCop, 40 RSpec examples and two Cucumber scenarios (10 steps). Collated
coverage was 64/64 executable lines and 8/8 branches, both 100%, with no
application or library exclusions. The gate's current advisory check also found
no vulnerabilities. Negative runs verified failing RSpec, undefined and pending
Cucumber steps, lint offenses, missing coverage results and a missing single
suite all fail. Adding an unloaded library file reduced line coverage to 95.52%
and branch coverage to 80%; the gate correctly rejected both.

A production image smoke check ran as UID 65534, prepared its schema twice and
served HTTP 200 from readiness, the Notes form and its stylesheet. Logs are
`/tmp/pbd-rails-conventions-verified-runtime.log`,
`/tmp/pbd-rails-conventions-negative.log` and
`/tmp/pbd-rails-conventions-production.log`. This remains local ARM64 runtime
evidence, not an amd64 cloud deployment or complete browser accessibility audit.

The repository's offline runner passed all 24 suites. On macOS Ruby 2.6 the
scaffold suite explicitly skips syntax parsing for the newer pinned Ruby;
independent Ruby 3.3.12 validation parsed all 32 generated Ruby files plus
Gemfile, `bin/rails`, Rakefile and config.ru, and ran the full application gate.
The skip does not establish generated syntax compatibility with Ruby 2.6.

The isolated conventions worktree has no new native Bash audit entries for this
work. Installed hook files do not establish runtime activation; hook activation
and complete command attribution remain unverified. Review instead uses the
independent diff, role handoffs and accepted-test hash comparisons. This does
not remove the audit limitation or turn absent entries into evidence of enforced
ownership.
