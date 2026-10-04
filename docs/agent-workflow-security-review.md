# Agent workflow migration security review

Reviewed 2026-10-04. This is a scoped advisory review, not a clean dependency
scan or a production exposure assessment.

## Commands and coverage

- `rg --files` with dependency-manifest and lockfile patterns found no Python
  dependency manifest or third-party Python requirements for the migrated engine.
  Import inspection confirms standard-library-only Python modules.
- `rg -n 'audit|security|advisori|bundler-audit' test .github docs scripts`
  found no repository dependency audit command.
- `command -v osv-scanner trivy grype pip-audit bundle-audit python3` found
  only `/opt/homebrew/bin/python3`; `python3 --version` reported **3.14.6**.
  No scanner was installed as part of this migration.
- Direct Python HTTPS retrieval of CVE records failed with DNS resolution
  errors in the execution sandbox. Browser-backed retrieval of the official
  Python release notes and PSF-authored CVE records succeeded; the records below
  were checked against that current advisory data.
- Terraform locks retain DigitalOcean provider 2.87.0, 2.89.0 and 2.100.0,
  and DNSimple 2.1.2 and 2.2.0. The DigitalOcean advisory page returned a
  seven-month-old cached page; DNSimple's advisory page could not be retrieved.
  Their current advisory status, transitive binaries, generated-app dependencies,
  deployment images and host packages were not comprehensively scanned.

## Pre-existing host Python findings

The runtime at the initial review was CPython **3.14.6**. The compatible patched release for
the applicable findings below is **3.14.8**, according to the
[official release notes](https://www.python.org/downloads/release/python-3148/).
The user subsequently upgraded Homebrew Python. On 2026-10-04, verification found
`python3` at `/opt/homebrew/bin/python3` reporting **3.14.8**, and
`brew list --versions python@3.14` also reported **3.14.8**. The six findings
below are therefore remediated for this active interpreter according to the
release notes. This verification does not cover other Python installations,
virtual environments, or processes already running the older interpreter.

Post-upgrade verification: `bash test/run.sh` passed all **18 suites** with
zero failures, including the lifecycle and workflow Python tests and shell
syntax checks. No application source or test changes were needed.

| Advisory | Affected range relevant to this host | Exposure condition |
| --- | --- | --- |
| [CVE-2026-19445](https://www.cve.org/CVERecord?id=CVE-2026-19445) | 3.14.0 through versions before 3.14.8 | A TLS server's SNI callback switches contexts and the original context loses its last reference; clients and servers retaining the context are not affected. |
| [CVE-2026-19553](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/19xxx/CVE-2026-19553.json) | 3.14.0 through versions before 3.14.8 | `SSLContext.wrap_bio()` with hostname checking enabled but a missing hostname can skip hostname verification. Supplying a valid hostname mitigates it. |
| [CVE-2026-15310](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/15xxx/CVE-2026-15310.json) | 3.14.0 through versions before 3.14.8 | Reading crafted ZIP members compressed with bzip2, LZMA or Zstandard can exhaust memory. |
| [CVE-2026-19672](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/19xxx/CVE-2026-19672.json) | CVE record still lists versions before 3.16.0; release notes report the fix in 3.14.8 | POSIX tar extraction with `tar`/`data` filters and crafted paths can create empty directories outside the destination. Randomized secure extraction directories mitigate it. The record's broad version range appears stale relative to the release notes. |
| [CVE-2026-15806](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/15xxx/CVE-2026-15806.json) | 3.14.0 through versions before 3.14.8 | `urllib.request.HTTPPasswordMgr` can reuse HTTPS credentials over HTTP to the same host after downgrade or redirect. |
| [CVE-2026-17084](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/17xxx/CVE-2026-17084.json) | 3.14.0 through versions before 3.14.8 | StringPrep/IDNA 2003 processing can mismatch domain names containing characters whose attributes changed after Unicode 3.2.0. |

The release notes also list
[CVE-2026-82049](https://raw.githubusercontent.com/CVEProject/cvelistV5/main/cves/2026/82xxx/CVE-2026-82049.json),
but its more specific PSF record does **not** classify the originally installed 3.14.6 as
affected: the 3.14 affected range is 3.14.0a1 through versions before 3.14.0b1.
Affected older branches are patched in 3.10.22, 3.11.17, 3.12.15 and 3.13.16.
The issue requires crafted tar hard links to symlinks and can change metadata
or disclose contents outside the extraction destination.

The imported workflow engine does not invoke SSL, tar/ZIP extraction,
HTTPPasswordMgr or StringPrep/IDNA APIs. No reachable use of these vulnerable
APIs was observed in this migration's code. This narrows the observed exposure;
it does not establish safety for other programs using the host interpreter or
all transitive runtime behavior. Advisory findings were routed to the
orchestrator; the user's subsequent runtime upgrade resolves the recorded host
version finding within the verification scope above.

## Workflow boundaries

Generated hooks restrict direct source/test edits by role; shell commands and
MCP operations are not complete filesystem confinement. Audit entries with
overlapping calls are ambiguous observations, not proof of an ownership
violation. Installing valid hook files does not establish native trust or runtime
activation. Codex CLI, Claude Code and desktop activation require separate
validation; this migration does not approve trust automatically.
