# Hook diagnostics verification

Verification date: 2026-10-08. Implementation reference: Healthie Journal branch
`codex/hook-diagnostics`, commit `c775f0f63ba26153d240aaa5f8695036d50b46ed`.
The upstream implementation and generated provenance must be verified separately
from native host activation.

## Test-first workflow and regeneration

The independent runner recorded the initial 21-test expected failure before
implementation; the reviewer accepted the contract. A further regression
demonstrated an unexpected diagnostic exception escaping with a private message
before the implementation isolated logging failures. Representation-only changes
to existing installation tests received renewed review without weakening their
assertions.

Before rebasing onto current main, authoritative verification with
`bash test/run.sh` exited 0: all **27 suites**
passed, with **122 workflow tests**, including **22 new diagnostics tests**.
Coverage includes real guard allow/deny and malformed-input parity, real audit
success/failure and caught skip parity, binary protocol streams, privacy,
child startup and logging failures, child and wrapper signals, a child that
catches a forwarded signal and exits 23, concurrent writers, bounded records,
owner-only permissions, foreign ownership, unsafe destinations, and busy locks.
Installer and app-lifecycle tests cover regeneration, provenance, ignores,
custom settings, and unrelated hooks within mixed registrations.

That pre-rebase installer regenerated the repository to component release
`0.5.0`, fingerprint
`ff994bf6e19f76aad1e253ec9d4a7ea3cde35dc10fd94d42a575cc32bebc3cfc`.
The independent reviewer compared all 26 manifest hashes against actual files,
confirmed source/generated wrapper and documentation equality, and found no
drift. `git diff --check` and Python AST parsing passed. Regeneration also synced
previously installed guidance and reviewer definitions to the already-maintained
upstream dead-code and doctest guidance; those changes are generated provenance,
not new rules authored for this feature.

Accepted SHA-256 test hashes remained unchanged after implementation and green:

| Test file under `test/agent-workflow/` | SHA-256 |
| --- | --- |
| `test_hook_diagnostics.py` | `816587720d4c04bba1ee7b70d2e516dda77d21c96e5a707e7779f691b5c16cc8` |
| `test_diagnostics_installation.py` | `4722acc2f80e0b2aa537b07e6b4365dedaf3c5683f1e5f58e2fb72c043a56607` |
| `test_maintenance.py` | `0711a9b37dccd2c7a7808bdaff4b9538284bae733890555a8ec52d21851c3f9f` |
| `test_claude_registration.py` | `acfaa9e19631527bfffce05008f82fc5b882473769f012961508c8830f37f660` |

The new audit entries were reviewed and contain no ownership violations.
No confirmed dead code or obsolete tests were removed. See the separate
[security review](hook-diagnostics-security-review.md) for advisory commands,
current results, pre-existing host Node findings, and scan limitations.

## Verification after rebasing onto main

The integrated installer remains release `0.5.0`, now with fingerprint
`4313db32b07320492217c7c22991f5e4f5d7d0c2ef035c00b695e1237f1851d2`.
All 26 generated manifest hashes match actual files. The generated wrapper and
diagnostic guide match their maintained sources. Main's model profiles,
coordination instructions, acceptance tooling, and canonical React guidance are
preserved. Private `.agent-diagnostics/` remains ignored and untracked.

The first integrated `bash test/run.sh` run failed one of 28 suites: the legacy
canonical-guide migration test still expected unwrapped hook commands and the
older installer manifest. The spec writer adapted that expectation to verify
exactly three diagnostic wrappers, their original command arguments, synchronous
execution, and preservation of the entire unrelated hook configuration. It also
checks the exact added manifest paths and their actual content hashes. No tests
were removed, and the independent reviewer accepted this integration contract.

Final `bash test/run.sh` exited 0 with **28 suites and zero failures**, including
syntax checks. Focused verbose unittest runs passed **19 diagnostics tests**,
**3 installation tests**, and **6 canonical-guide tests**. Full output, including
the initial failure, is under `/tmp/diagnostics-rebase-evidence/`:
`full.log`, `full-final.log`, `test_hook_diagnostics.py.log`,
`test_diagnostics_installation.py.log`, and `canonical-final.log`.

The four diagnostics contract hashes above remain unchanged. The revised
`test/agent-docs/test_canonical_guides.py` hash is
`e4891fee9e908bd864f9d16e53bc8ae75fac1f45372db7b3e2bea2c1a8bdb37f`.
Final staged and working-tree whitespace checks passed. No confirmed dead code
was found. The reviewer refreshed `npm audit --json --package-lock-only` against
current advisory data: zero findings across 118 dependencies. Previously reported
host Node findings and infrastructure scan limits remain unchanged. Ruby RSpec,
Cucumber, ExUnit, and Cucumberex runtime checks are unrelated to this Python hook
change; inherited generated tooling was preserved and its repository checks pass.

## Native host checks

### Codex CLI

The installed CLI reports `codex-cli 0.160.0`. An interactive startup using
`codex --no-daemon --no-alt-screen --cd /Users/jeffreybaird/src/push-button-deploy`
initially failed with `Operation not permitted (os error 1)` under the filesystem
sandbox. An approved execution outside that sandbox succeeded. No hook-trust
bypass flag was used.

Before regeneration, `/hooks` reported two installed and active `PreToolUse`
hooks and one installed and active `PostToolUse` hook. This checks the previous
registration only; it is not evidence that the diagnostics wrapper is active.

After regeneration to component release `0.5.0`, a fresh CLI startup reported
`3 hooks are new or changed` and required native review. Its hook browser showed
`PreToolUse`: installed 2, active 0, review 2; `PostToolUse`: installed 1,
active 0, review 1. This establishes discovery and the trust gate, not invocation.
The CLI warned that trusted hooks can run outside the sandbox. Approval to trust
these exact reviewed definitions was requested; no trust bypass was used.

### Codex Desktop

The native UI automation attempt to inspect Codex returned: `Computer Use is not
allowed to use the app 'com.openai.codex' for safety reasons.` Desktop hook review
and native invocation could therefore not be verified through that interface.
CLI activation, subprocess tests, and installed files do not establish Desktop
activation. That UI attempt did not verify Desktop activation.

During the later rebase verification in this Desktop session, a read-only native
command probe invoked no diagnostics subprocess itself. The runner observed the
local record count increase from 153 to 161, including successful guard
`PreToolUse` and audit `PreToolUse`/`PostToolUse` records. All observed records had
the exact seven-field schema; directory and file modes were 0700 and 0600, and
Git ignored the log. The evidence is
`/tmp/diagnostics-rebase-evidence/native-observation.log`. This establishes
invocation in the active session, not full Desktop validation: exact-definition
trust review, native allow/deny probes, restart persistence, relocation, and host
timeouts remain unverified. CLI activation was not retested during this rebase.

### Remaining native procedure

Review the exact regenerated definitions in each host's hook management UI, then
run a harmless native shell call and confirm new local diagnostic records for
the guard and both audit events. Verify an allowed implementer source edit, an
allowed spec-writer test edit, and a denied parent source/test edit in a disposable
checkout. Restart the host and repeat; also check invocation from a nested
directory and a relocated checkout. Record each host version and result separately.

Changed definitions may need renewed trust. The
[official hook documentation](https://learn.chatgpt.com/docs/hooks) describes
definition-specific review and trust through `/hooks`. A missing diagnostic
record alone cannot distinguish absent activation from a best-effort logging
failure.
