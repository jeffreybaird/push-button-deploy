# Code-host and CI adapters

Source `scripts/provider.sh` after resolving configuration. It keeps the public
API used by bootstrap, teardown and deployment; callers do not source adapters.
The facade selects a namespaced implementation without `eval`. Dispatch runs in
the caller's shell, preserving stdin, exit status and resolved authentication
state. Sourcing initializes defaults and functions but performs no remote calls.

## Responsibilities

| File | Responsibility |
|---|---|
| `../provider.sh` | Defaults, provider validation, public API and dispatch |
| `github.sh` | GitHub operations through `gh` and local Git |
| `gitea-http.sh` | Authenticated REST transport, body/status response modes |
| `gitea-auth.sh` | Credential check, owner resolution and minimum version check |
| `gitea-repository.sh` | Repository lifecycle, origin setup and transient push authentication |
| `gitea-settings.sh` | Actions secrets and variables |
| `gitea-runs.sh` | Actions queries, dispatch, diagnostics and pure run normalization |

Application policy remains in `scripts/bootstrap/config.sh`. Infrastructure
creation and polling/retry decisions remain in their existing modules. Adapters
translate provider operations; they do not provision infrastructure or wait for
deployments.

## Shared context

The existing API consumes resolved shell variables:

- `GIT_PROVIDER`: `github` (default) or `gitea`; checked at source and dispatch.
- `APP_NAME`: repository name. GitHub existence and remote URL queries use it
  explicitly; other GitHub repo operations use the current working directory.
- `APP_DIR`: directory for GitHub workflow queries, dispatch and diagnostics.
- `CI_WORKFLOW`: defaults to `deploy.yml`; build-only apps use `ci.yml`.
- `HEAD_SHA`: the commit whose run is being polled.
- Gitea configuration: `GITEA_URL`, `GITEA_TOKEN`, optional `GITEA_OWNER`.
  `ci_auth_check` sets `GITEA_AUTH_LOGIN` and `GITEA_OWNER_RESOLVED` in the
  caller's shell. Call it before Gitea repository/settings/Actions operations.

`ci_run_row [app_dir [workflow [commit]]]` scopes explicit overrides with Bash
locals; adapter functions see those values and caller globals remain unchanged.
Repository mutations, settings and Git push keep their existing calling-directory
requirements. A future explicit context API can replace these globals separately.

## Public contract

| Operation | Result / error behavior |
|---|---|
| `ci_auth_check` | Validates credentials; calls `fail` on failure |
| `repo_exists` | Zero if found; nonzero otherwise |
| `repo_remote_url` | Clone/remote URL on stdout |
| `repo_create` | Creates a private repo and wires origin; errors propagate |
| `repo_delete` | Deletes current app repo; calls `fail` on failure |
| `provider_git_push args...` | Forwards arguments and Git exit status |
| `secret_set name` | Reads value from stdin, sends to provider |
| `var_set name value` | Sets variable; Gitea creates only after an update returns 404 |
| `var_delete name` | Best effort, including absent variables |
| `ci_run_row ...` | `id status conclusion`, or empty output if unavailable |
| `ci_dispatch_deploy` | Dispatches selected workflow on `main`; failure calls `fail` |
| `ci_watch_hint`, `ci_log_hint` | Provider-specific command or URL |
| `ci_diagnose_dump` | Human-readable recent run information, best effort |

Gitea HTTP helpers distinguish two modes: `gitea_api` prints a response body and
fails on HTTP errors; `gitea_api_status` prints the HTTP code for the adapter to
interpret. Connection errors remain nonzero. No credentials are stored in origin
URLs. The public secret API consumes stdin; transport encoding remains internal.

## Compatibility limits

This refactor preserves existing API requests and error policy. In particular:

- `repo_exists` does not distinguish missing repositories from authorization or
  transport failures. Changing that requires a coordinated caller/API change.
- Gitea task selection is commit-based and is not filtered by `CI_WORKFLOW`;
  GitHub queries include both workflow and commit. Multiple workflows for one
  Gitea commit remain an integration issue to address separately.
- Polling treats missing/malformed responses as unavailable; the deployment layer
  owns retry/timeout behavior. Variable deletion remains best effort.

## Verification

Run `bash test/run.sh`. `test/provider-contract.sh` exercises the public facade
with fake `gh`/`curl`, real JSON encoding and local Git repositories.
`test/provider-runs.sh` exercises run selection and normalization against fixtures.
Neither makes live requests. Live provider compatibility is outside this suite.
