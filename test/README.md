# Repository regression tests

Run the deployment tool's tests from any directory:

```bash
bash /path/to/push-button-deploy/test/run.sh
```

Requirements: Bash, Ruby (standard library only), jq, Perl, Git, and standard
Unix utilities. No Docker daemon, Terraform installation, cloud credentials,
Elixir, Ruby gems, or generated application dependencies are required. The
repository workflow runs the same command with `/bin/bash` on Linux and macOS,
covering Bash 5 and Apple's Bash 3.2 respectively.

## Isolation and failure reporting

Each suite runs in a separate process with a clean environment and temporary
working files. The runner does not source your `.env`, inherit cloud credentials,
or use your global Git configuration. Real cloud/transport commands are replaced
with guards; suites install their own boundary doubles where needed. Even a
swallowed unexpected external call fails its suite. Temporary files are removed
on exit, and failed suites print their captured output. The runner continues
through all suites and exits nonzero if any test or syntax check failed.

All top-level `test/*.sh` (except the runner) and `test/*.rb` files are discovered
automatically. Fixtures and assertion helpers live in subdirectories.

## Covered behavior

| Suite | Contract |
|---|---|
| `release-task.sh` | Check-only and repeat runs preserve custom release code; invalid existing files are never overwritten. |
| `config.sh` | Caller precedence, explicit empty/multiline values, exports, redacted diagnostics, app policy and a real CLI preflight with mocked authentication. |
| `deployment.sh` | Old runs cannot satisfy a new deployment; CI success precedes HTTPS; terminal failures and HTTPS timeout fail. |
| `ci-trigger.sh` | Real local Git commits/pushes, no-change dispatch, already-running CI reuse, immediate run registration and failed pushes. |
| `provider-runs.sh` | GitHub query identity and empty results; Gitea response envelopes, commit filtering, ordering, status normalization and malformed responses. |
| `swap.sh` | Both colors, first deployment, no supporting services, SQLite support services, failed candidates/configuration/support startup and missing containers. |
| `bootstrap-app.sh` | Generated deployment artifacts across 18 stack/backend/provider combinations. |
| `workflow-scripts.sh` | Literal env serialization, private permissions, staging backup omission, remote destinations and shared-edge preservation. |
| `workflow-templates.rb` | YAML parsing, shell syntax, helper availability, migration-before-swap and no-migration rollback contracts. |
| `claude-docs-regression.sh` | App-owned docs preservation, reruns, literal replacement, hook validation and symlink rejection. |
| `claude-docs-smoke.sh` | Document injection, placeholders, optional modules, agents and hooks. |
| `assertion-contract.sh` | Negative assertions reject both unexpected success and errors in the assertion command. |

## Writing a regression test

Test observable outputs, exit status, filesystem changes and boundary calls.
Execute deploy scripts in a separate Bash process; sourcing them inside an `if`
or `||` expression can suppress their real `set -e` behavior. Mock cloud APIs,
SSH and Docker, while using real local files, Git and parsers where practical.

For an expected negative match, source `test/helpers/assertions.sh` and call
`assert_not grep ...`. A standalone `! grep ...` is exempt from Bash's errexit
and does not reliably fail a test when the match unexpectedly exists. Likewise,
use separate assertions instead of joining them with `&&`.

These are offline contract/regression checks, not end-to-end deployment tests.
They do not establish real Compose health/network behavior, cloud provider API
compatibility, or Terraform lifecycle isolation. `scripts/verify-isolation.sh`
is a separate live-state check and is intentionally outside this runner.
