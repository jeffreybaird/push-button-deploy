# Independent model-profile implementation review

Accepted 2026-10-08 after independent implementation/final-diff review and authoritative green. No implementation blockers or findings.

Reviewed the complete tracked diff and three untracked additions (profile and two accepted tests), source call paths, generated local configuration, complete focused RED/GREEN logs, and preview/apply/check evidence. Four accepted hashes match `accepted.sha256`. Source/test files were not edited by this reviewer. `git diff --check` passes.

## Implementation and preservation

The optional profile validates schema, platform/role/field keys, types, native effort vocabulary and ordinary-file/parent safety before mutations. Its source is outside generated manifests and remains project-owned. JSON string serialization protects TOML/YAML fields; the TOML overlay parses input/output and scans strings, comments and nesting to preserve unrelated text. Nonstandard root key spellings fail safely rather than overwrite unrelated content. Every added helper has a live call path: render -> model_profile and overlay_toml_model -> toml_statements; lifecycle consults the explicit main model to avoid retaining a stale app-owned main value. Direct install, registered maintenance and lifecycle are covered.

Local generated selections match the requested main models and reviewer/runner overrides. Role instruction bodies, policy files and hook commands are unchanged. Other role files inherit. Missing/removed main overrides retain native values; role fields regenerate to inheritance. Local check reports current at 0.4.2; native activation remains UNKNOWN, and availability of configured model identifiers is a host concern.

## Dead-code and audit review

No confirmed dead code found. New helpers/constants are exercised by the public installer and lifecycle entry points; no existing API was orphaned or removed. No source/test deletion, no test-removal patch, no pending test-deletion approval. Existing live coverage is retained and the accepted additions exercise new behavior.

The audit log is unchanged for this feature. Its latest ambiguous runner-attributed entry concerns the prior 0.4.1 canonical test revision, whose accepted spec-writer provenance is documented in `.agent-audit/coordination-efficiency-review.md`. It does not establish a model-profile ownership violation. Unchanged hashes and reviewed diffs support preservation; absence of new audit entries does not prove hook activation or complete command attribution.

## Security advisory review

Commands: `python3 --version` -> 3.14.8; `node --version` -> v26.0.0; `command -v pip-audit osv-scanner trivy grype bundle-audit` -> no installed scanners. This standard-library engine adds no dependencies and has no repository-wide security audit gate. Read the complete workflow, React, Rails and coordination security reports. Historical application audits were not rerun; they are not current clean scans.

Current official Python 3.14.8 release notes (https://www.python.org/downloads/release/python-3148/) reconfirm the six historical host findings fixed in active 3.14.8: CVE-2026-19445 (SNI context lifetime), CVE-2026-19553 (wrap_bio hostname), CVE-2026-15310 (compressed ZIP memory), CVE-2026-19672 (tar extraction paths), CVE-2026-15806 (HTTPPasswordMgr downgrade credentials), CVE-2026-17084 (StringPrep/IDNA). Relevant affected 3.14 releases precede 3.14.8; the stored review records the tar CVE metadata discrepancy. CVE-2026-82049 does not affect active 3.14.8; older branches fixed in 3.10.22/3.11.17/3.12.15/3.13.16. Other installations are unverified.

Unresolved pre-existing host Node 26.0.0 predates fixes in 26.5.1 (24.18.1/22.23.2 on applicable branches). Rechecked official July advisory https://nodejs.org/en/blog/vulnerability/july-2026-security-releases on 2026-10-08. Conditions: CVE-2026-56848 HTTP2 reentrancy; CVE-2026-58043 permission path matching; CVE-2026-56847 permission trace writes; CVE-2026-58039 permission report writes; CVE-2026-56850 PFX identity reuse; CVE-2026-58040 TLS hostname-policy reuse; CVE-2026-58041 cached SQLite iterators; CVE-2026-58042 resolveAny responses; CVE-2026-58045 sync zlib typed-array lengths; CVE-2026-58044 forwarding-proxy headers. API reachability remains uncertain. Generated Node24.21.0 includes these fixes. Findings routed to coordinator; global host upgrades are not authorized. No advisory suppressed.

Retained historical Caddy findings: GHSA-6365-7ppr-5r92 affects <2.11.5 with forward_auth/reverse_proxy combinations; prior 2.11.4 pin was updated to 2.11.7. GHSA-j8px-rmrx-76h9 affects <=2.11.3 and is patched2.11.4; rewrite placeholders/body buffering/hidden-file matching are relevant. Existing deployments and custom modules remain uncertain. Full exact Ruby advisory inventory (Puma, Active Storage, sanitizer, resolv, ERB, zlib, URI, CGI and net-imap), affected/resolved versions and conditions is incorporated by reference to `docs/rails-security-review.md`, which was read in full. Those historical resolved application audits are unchanged and unrefreshed for this Python feature. Terraform provider binaries, Litestream, OS/container packages and deployed copies remain incompletely scanned.

## Evidence reviewed

Full focused runner logs: green-agent-workflow (10), green-agent-docs (2), green-maintenance (18), green-canonical-guides (6), green-coordination-guidance (6), all exit0; no skips/pending examples. Full original RED failures were inspected and retained. implementation-preview.log, preview-configure/check/diff.log, local-prospective.diff, local-apply.log and local-check.log inspected. The implementation preview log is a summary of manual checks, not a substitute for runner output.

Ruby Cucumber/RSpec and Elixir Cucumberex/ExUnit execution are N/A for this Python model-configuration feature; it changes no application testing tooling. The PR must contain readable model-profile acceptance scenarios and actual relevant Python/Bash output, and retain prior PR evidence for other included changes.

## Final full-gate result

Read complete `green-bash-suite.log`: `bash test/run.sh` exits 0; all 28 suites pass, zero failures including syntax checks. Complete per-suite PASS output is retained in that file. Rechecked all four accepted SHA256 hashes and `git diff --check` after gate completion; all pass. No skipped/pending cases reported in the focused logs or full-suite summary; the wrapper summary does not expose every internal test detail. Final acceptance preserves the unresolved host Node finding and native activation/scanner limitations above.

## Supplemental generated-app and PR evidence review

Read complete `green-generated-app-idempotence.log`: both lifecycle updates exit0, both preserve profile bytes and nanosecond mtime, second update reports all managed bytes unchanged, and the printed 12 native settings/role SHA256 values match across runs. Accepted as additional authoritative runner evidence.

Read `/tmp/pbd-agent-models/pr-body.md`: contains readable acceptance scenarios, actual focused output and commands, full-gate result, reasoned Ruby/Elixir N/A, dead-code report and unresolved security limits. The historical 0.4.1/116-hash coordination evidence should be labeled explicitly as prior coordination validation so readers do not mistake it for the current four-file profile contract. No source/test change or renewed implementation gate is required for that prose clarification.
