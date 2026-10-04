# Agent workflow migration evidence

Validation date: October 4, 2026.

The shared workflow engine moved from `agent-workflow-setup` into
`scripts/agent-workflow/`. The old repository retains its source and history;
no other application's generated files were rolled out during this migration.
Homebrew packaging was inspected for compatibility and remains separate work.

## Accepted behavior

The combined tool owns initial agent-doc installation and subsequent maintenance.
Apps retain their own project guidance and unrelated native settings. Shared
regions, modules, role definitions, hook registrations, and installed selections
are tracked locally. Updates reject managed drift before writes and preserve
unchanged files on repeat runs. Bootstrap adopts apps without a lifecycle
manifest; already-managed apps use explicit maintenance commands for updates.

The new lifecycle works for arbitrary app names and does not require a Git
checkout or writable installation bundle. Registered-repository maintenance
remains available for existing workflow-only targets. Component fingerprints
replace source Git HEAD as provenance so unrelated commits do not cause updates.
Legacy managed-target edit safeguards remain in force.

## Test-first evidence

The mandatory workflow used separate test-writer, runner, implementer, and
reviewer agents. Accepted test hashes were frozen before implementation and
compared afterward. Archived version-one tests were preserved byte-for-byte.

Phase one imported the existing engine and active contracts. The original
baseline passed 97 Python tests and 16 deployment regression suites. The imported
tests then failed because the new source location was absent. After import,
97 Python tests and all 16 deployment suites passed; the independent reviewer
accepted the source copy and all 24 frozen test/archive files. Commit `cb8ad4e`
contains that complete import and an SSH signature.

Phase two explicitly revised provenance and generation expectations before
implementation. Its initial red run covered 18 regression suites, with six
expected failing suites for the absent lifecycle and changed generation
contracts. The reviewer accepted the lifecycle contract and 34 frozen test and
contract files. Additive reviewed regressions then covered bootstrap preservation,
TypeScript policy scope, the minimum Python version, module retirement, framework
switching, and both template-guide layouts. The release assertion was explicitly
updated to component version `0.3.0` with renewed acceptance.

The first complete candidate passed all 18 suites (21 lifecycle tests, 99 workflow
tests, and the shell/Ruby suites). Independent review then found retired-template
and framework-switch cleanup gaps. Five evolution tests were added: three
reproduced those gaps, and two confirmed existing testing-guide update/drift
behavior. The retirement fixture removed the module from both bundled framework
roots so it exercised a genuinely retired path rather than another framework's
still-valid path. Final verification is recorded below after these corrections.

Two earlier narrow fixes landed before their additive regression run because
agents were working concurrently. The implementer temporarily restored only the
pre-fix JSON-policy and Python-preflight behavior; the runner then recorded genuine
failures, the reviewer accepted the tests, and the implementer reapplied the fixes.
No already-green run was presented as failing evidence.

## Final verification

The final component release is **0.3.0**; the workflow contract remains **2.0.0**.
The authoritative final `bash test/run.sh` run passed all **18 suites** with zero
failures, including **28 lifecycle tests and 99 workflow tests**, shell syntax,
and the existing Ruby/shell regression suites. The runner also parsed all six
Python source modules, checked `git diff --check`, and compared all **40** final
accepted test/contract file hashes. All matched.

Independent review accepted the implementation, ownership policies, generated
self-manifest, and audit attribution. The repository's own registered-workflow
check reported `current`, release `0.3.0`, and no drift. The
[durable validation artifact](../.agent-audit/migration-validation.json) records
commands, expected red outcomes, final results, runtime, and accepted hashes.

The final regressions also cover stale saved selections after upstream module
retirement and invalid native TOML table types. Recorded retired choices are
normalized while other preferences persist; new misspelled options still fail.
Malformed native settings return structured errors before target writes.

## Security and runtime limits

See [Security review](agent-workflow-security-review.md) for the current advisory
sources, host Python finding, exposure assessment, and unavailable audit tools.
The migrated component uses the Python standard library; no third-party runtime
dependency was added. Host administration is outside this migration.

Offline tests do not establish live deployment behavior, cloud API availability,
or native hook trust/invocation. Hook activation must be validated separately for
Codex CLI, desktop, and Claude Code. No hook trust settings were changed.

## Audit attribution

Concurrent agents can produce shell-audit entries naming files another role
changed during the same interval. The reviewer checked those ambiguous entries
against tool overlap, commands, source diffs, and frozen tests. The audit log is
committed with the work; ambiguous observations are not treated as proof that
the observing runner edited tests.
