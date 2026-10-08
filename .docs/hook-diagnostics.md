# Local Codex hook diagnostics

Generated Codex workflow guard and audit registrations run through
`.codex/hooks/hook_diagnostics.py`. The wrapper inherits hook stdin and stdout,
forwards every stderr byte, and preserves child exit status, termination signal,
and permission decisions. It does not parse or change protocol output.

The ignored local file `.agent-diagnostics/hooks.jsonl` contains only seven fields:
fixed hook and event identity, UTC timestamp, duration in milliseconds, exit code
or signal, and an allowlisted error category. No payload, command, raw stderr,
exception message, path, credential, or other secret enters these records.
Original raw stderr still reaches the hook's stderr destination.

Categories identify nonzero exits, child startup failure, signal termination,
Python traceback markers, and caught `workflow audit skipped` errors. Exception
class names are restricted to a fixed allowlist; unknown classes receive a generic
category. The existing audit hook's successful exit after a caught exception
remains successful. Its separate `.agent-audit/bash.jsonl` has different storage
and privacy rules, documented in the agent workflow.

Diagnostics retain at most 65,536 bytes of complete JSON lines. The directory uses
mode 0700 and the file mode 0600, owned by the effective user. Writers use file
descriptors, refuse symlinks, nonregular files, hardlinked files, and destinations
owned by another user, and take a nonblocking exclusive lock. A busy lock or a
logging failure skips a record without changing hook behavior. Missing records
therefore do not prove that hooks did not run.

## Limits and activation

The wrapper cannot report its own startup failure, missing Python, or shell setup
failure before Python starts. SIGKILL of the wrapper, host loss, and host timeouts
can prevent a record; a host may kill the wrapper and child separately. SIGTERM
and SIGINT are forwarded to the active child. The wrapper is not a process-tree
supervisor. A child killed while the wrapper survives can be recorded.

Stderr is relayed through a pipe to classify errors with a bounded in-memory
window. Its bytes and destination are preserved, but timing and interleaving may
change, and the child sees a pipe rather than the original stderr file descriptor.
Classification is best effort and is not proof of a specific exception.

Verify Codex Desktop and Codex CLI independently, including host version, reviewed
definitions, native invocation, allowed and denied role probes, and restart
behavior. Installing files or passing subprocess tests does not establish hook
trust or activation. Review changed definitions through the host's hook UI where
required; the installer never grants trust itself. Host timeout behavior also
requires native validation. SIGHUP and SIGQUIT are also forwarded to the child.

## Generated provenance

The maintained Push Button Deploy installer owns the wrapper, registration,
ignore rule, and this document. Both workflow and app lifecycle manifests record
the generated content accurately. Regeneration preserves the wrapper and
unrelated hook configuration. Provenance uses a deterministic component content
fingerprint rather than a repository commit identifier. The original design was
adapted from Healthie Journal branch `codex/hook-diagnostics`, commit `c775f0f`.
