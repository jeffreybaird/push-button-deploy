# React support security review

Reviewed 2026-10-07. This is a scoped dependency and configuration review, not a
comprehensive scan of existing deployments, operating systems, or cloud accounts.

## Dependency audit

The repository has no repository-wide dependency audit command. The reviewer ran
`npm audit --json --package-lock-only` in `app-react/`, including development
dependencies. The initial sandbox request failed with DNS `ENOTFOUND`; an approved
network-enabled retry queried the npm advisory service successfully and exited 0:
zero vulnerabilities at every severity, with 118 dependencies in audit metadata.
This checks the committed lockfile; it does not audit the host Node binary or
prove future dependency resolutions safe. No advisories were suppressed.

The authoritative runner additionally installed the generated app with `npm ci`
on Node 24.21.0, passed its interaction test, TypeScript check and production
build, and ran `npm audit` successfully with zero findings including development
dependencies. Logs are under `/tmp/react-support-evidence/`. The reviewed source
lockfile SHA256 is
`3368081541c454f3072801c0a19d4230716724b6b7b4deca9a83c664c8199618`.

The starter pins React/react-dom 19.3.0, Vite 8.3.3, Vitest 5.0.3, TypeScript
6.0.3, jsdom 30.1.2, and Node 24.21.0. Production serves built files through Caddy;
it has no Node application process, API handlers, or database. The template warns
that browser code and `VITE_*` variables are public, and ignores local env files.

## Pre-existing Caddy finding and fix

The shared edge template previously pinned Caddy 2.11.4. Current official advisory
[GHSA-6365-7ppr-5r92](https://github.com/caddyserver/caddy/security/advisories/GHSA-6365-7ppr-5r92)
affects versions before 2.11.5: combining `forward_auth` with `reverse_proxy` can
connect to the wrong upstream. The generated React route uses neither directive,
but custom routes on the shared proxy may. The compatible template upgrade to
2.11.7 addresses this version finding. This does not update already deployed
copies until their edge stack is redeployed.

The runner exercised the actual Caddy 2.11.7 image: `/`, `/index.html`, and a
deep client route returned the exact entry HTML with `Cache-Control: no-cache`;
missing JavaScript/CSS returned 404, and an existing built asset returned its
actual bytes. These checks do not prove live cloud deployment or custom routes.

[GHSA-j8px-rmrx-76h9](https://github.com/caddyserver/caddy/security/advisories/GHSA-j8px-rmrx-76h9)
affects Caddy through 2.11.3 and is patched in 2.11.4; the former pin already
included that fix. Its conditions involve request-derived rewrite placeholders,
body buffering, or hidden-file matching. Container OS packages, bundled Go
dependencies, and arbitrary custom Caddy modules were not comprehensively scanned.

## Unresolved host Node finding

The review host reports Node **26.0.0**, predating the
[July 2026 security release](https://nodejs.org/en/blog/vulnerability/july-2026-security-releases).
Relevant identifiers and exposure conditions are:

| Advisory | Required feature or operation |
| --- | --- |
| CVE-2026-56848 | Re-entrant HTTP/2 processing |
| CVE-2026-58043 | Permission-model path matching |
| CVE-2026-56847 | Permission-model trace-event writes |
| CVE-2026-58039 | Permission-model process-report writes |
| CVE-2026-56850 | HTTPS agent reuse across PFX client identities |
| CVE-2026-58040 | TLS session reuse with differing hostname policies |
| CVE-2026-58041 | SQLite cached iterator reuse |
| CVE-2026-58042 | `dns.resolveAny()` with oversized responses |
| CVE-2026-58045 | Synchronous zlib with spoofed typed-array length |
| CVE-2026-58044 | Node forwarding proxies rebuilding headers |

These fixes shipped in **26.5.1**, **24.18.1**, and **22.23.2** for applicable
branches. The generated Node **24.21.0** pin includes them. Host API reachability
was not exhaustively assessed. Updating the user's global Node installation is
outside this repository change; use a current patched runtime for development.

## Other pre-existing findings and limits

The [Rails security review](rails-security-review.md) records dependency versions,
advisory identifiers, patched versions, and exposure conditions for Ruby/Puma and
related gems. The reviewer inspected the stored Rails, Sinatra, and Ruby CLI audit
logs under `/tmp/pbd-rails-audit/`; all report zero findings against
`ruby-advisory-db` revision `b6604fa6b54cb6e9a140e3a12d1f1d15b695330c`, updated
2026-10-07 20:03 EDT. Those Ruby audits were not rerun for this change. Existing
applications with older runtimes or locks need their own audits.

The active host Python reports **3.14.8**, matching the remediation recorded in
the [workflow security review](agent-workflow-security-review.md). Other Python
installations are not covered. Terraform providers, Litestream, operating-system
packages, and existing deployment images remain outside comprehensive scan
coverage; their advisory status is uncertain.

## Final review evidence

`bash test/run.sh` passed all 26 suites with zero failures, including shell
syntax checks (`/tmp/react-support-evidence/green-accepted-suite.log`). The
teardown failure regression was also demonstrated against the prior permissive
implementation before restoring the fix and running the full green suite.
Malformed package metadata now stops teardown before destructive operations.

All nine accepted test/fixture hashes matched at final review. Reviewed fixture
corrections added the React template to relocated bundles, retained Ruby 2.6
compatibility, and updated the installer version assertion without weakening
behavior. New ownership-audit violations were marked ambiguous and overlapped
the responsible writers' changes; final diffs and hashes did not establish an
unauthorized source/test edit. No live infrastructure was provisioned or destroyed
by these checks.
