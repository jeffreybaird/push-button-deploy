"""Forward a managed hook unchanged and retain bounded, secret-free diagnostics."""

import argparse
from datetime import datetime, timezone
import fcntl
import json
import os
import re
import signal
import stat
import subprocess
import sys
import time


MAX_BYTES = 65_536
AUDIT_ERRORS = frozenset({
    "ValueError", "TypeError", "KeyError", "RuntimeError", "OSError",
    "FileNotFoundError", "PermissionError", "UnicodeDecodeError", "JSONDecodeError",
})


def stream_stderr(child):
    """Forward every byte while retaining only a small classification window."""
    tail = b""
    audit_category = None
    traceback_seen = False
    while True:
        chunk = os.read(child.stderr.fileno(), 4096)
        if not chunk:
            break
        sys.stderr.buffer.write(chunk)
        sys.stderr.buffer.flush()
        sample = tail + chunk
        traceback_seen |= b"Traceback (most recent call last):" in sample
        for match in re.finditer(rb"workflow audit skipped: ([A-Za-z_]+)\r?\n", sample):
            name = match[1].decode("ascii")
            audit_category = "audit_skipped_" + (name if name in AUDIT_ERRORS else "unknown")
        tail = sample[-256:]
    return traceback_seen, audit_category


def execute(command):
    """Inherit protocol streams and relay termination signals to the active child."""
    child = None
    pending = None

    def forward(number, _frame):
        nonlocal pending
        if child is None:
            pending = number
        elif child.poll() is None:
            try:
                child.send_signal(number)
            except ProcessLookupError:
                pass

    previous = {number: signal.signal(number, forward) for number in
                (signal.SIGTERM, signal.SIGINT, signal.SIGHUP, signal.SIGQUIT)}
    try:
        try:
            child = subprocess.Popen(command, stderr=subprocess.PIPE)
        except OSError:
            return 127, "startup_failure"
        if pending is not None:
            forward(pending, None)
        traceback_seen, audit_category = stream_stderr(child)
        code = child.wait()
        if code < 0:
            return code, "signal"
        if traceback_seen:
            return code, "unhandled_exception"
        if audit_category:
            return code, audit_category
        return code, "nonzero_exit" if code else None
    finally:
        if child is not None:
            child.stderr.close()
        for number, handler in previous.items():
            signal.signal(number, handler)


def write_record(root, record):
    """Refuse unsafe destinations and never wait for another diagnostic writer."""
    descriptors = []
    try:
        root_fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        descriptors.append(root_fd)
        try:
            os.mkdir(".agent-diagnostics", 0o700, dir_fd=root_fd)
        except FileExistsError:
            pass
        directory = os.open(".agent-diagnostics", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=root_fd)
        descriptors.append(directory)
        if os.fstat(directory).st_uid != os.geteuid():
            return
        try:
            existing = os.stat("hooks.jsonl", dir_fd=directory, follow_symlinks=False)
        except FileNotFoundError:
            existing = None
        if existing is not None and (not stat.S_ISREG(existing.st_mode) or
                                     existing.st_nlink != 1 or existing.st_uid != os.geteuid()):
            return
        log = os.open("hooks.jsonl", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK,
                      0o600, dir_fd=directory)
        descriptors.append(log)
        metadata = os.fstat(log)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1 or metadata.st_uid != os.geteuid():
            return
        fcntl.flock(log, fcntl.LOCK_EX | fcntl.LOCK_NB)
        os.fchmod(directory, 0o700)
        os.fchmod(log, 0o600)
        size = os.fstat(log).st_size
        offset = max(0, size - MAX_BYTES)
        data = os.pread(log, MAX_BYTES, offset)
        if offset:
            data = data.partition(b"\n")[2]
        data += json.dumps(record, separators=(",", ":")).encode("ascii") + b"\n"
        if len(data) > MAX_BYTES:
            data = data[data.index(b"\n", len(data) - MAX_BYTES) + 1:]
        os.lseek(log, 0, os.SEEK_SET)
        remaining = memoryview(data)
        while remaining:
            remaining = remaining[os.write(log, remaining):]
        os.ftruncate(log, len(data))
    except (OSError, ValueError):
        # Diagnostics are best effort and cannot change a managed hook decision.
        pass
    finally:
        for descriptor in reversed(descriptors):
            try:
                os.close(descriptor)
            except OSError:
                pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--hook", choices=("workflow_guard", "workflow_audit"), required=True)
    parser.add_argument("--event", choices=("PreToolUse", "PostToolUse"), required=True)
    parser.add_argument("--root", required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("a child command is required")
    started = time.monotonic()
    code, category = execute(command)
    try:
        write_record(args.root, {
            "hook": args.hook,
            "event": args.event,
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "duration_ms": round((time.monotonic() - started) * 1000, 3),
            "exit_code": code if code >= 0 else None,
            "signal": -code if code < 0 else None,
            "error_category": category,
        })
    except Exception:
        # Completed hook outcomes take precedence over every diagnostic failure.
        pass
    if code < 0:
        if -code not in (signal.SIGKILL, signal.SIGSTOP):
            signal.signal(-code, signal.SIG_DFL)
        os.kill(os.getpid(), -code)
    return code


if __name__ == "__main__":
    sys.exit(main())
