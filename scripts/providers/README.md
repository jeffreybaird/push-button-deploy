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
| `errors.sh` | Shared absence/error status contract |
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
  explicitly; an unqualified name is resolved against the authenticated user; other GitHub
  repo operations use the current working directory.
- `APP_DIR`: directory for GitHub workflow queries, dispatch and diagnostics.
- `CI_WORKFLOW`: defaults to `deploy.yml`; build-only apps use `ci.yml`.
- `HEAD_SHA`: the commit whose run is being polled.
- Gitea configuration: `GITEA_URL`, `GITEA_TOKEN`, optional `GITEA_OWNER`.
  `ci_auth_check` sets `GITEA_AUTH_LOGIN` and `GITEA_OWNER_RESOLVED` in the
  caller's shell. Call it before Gitea repository/settings/Actions operations.

`ci_run_row [app_dir [workflow [commit]]]` scopes explicit overrides with Bash
locals; adapter functions see those values and caller globals remain unchanged.
Repository mutations, settings and Git push keep their existing calling-directory
requirements. These inputs are the supported context contract; callers must
resolve them before dispatch.

## Public contract

| Operation | Result / error behavior |
|---|---|
| `ci_auth_check` | Validates credentials; calls `fail` on failure |
| `repo_exists` | 0 found, 1 HTTP 404, 2 auth/transport/server/protocol error |
| `repo_remote_url` | Clone/remote URL on stdout |
| `repo_create` | Creates a private repo and wires origin; errors propagate |
| `repo_delete` | Deletes current app repo; calls `fail` on failure |
| `provider_git_push args...` | Forwards arguments and Git exit status |
| `secret_set name` | Reads value from stdin, sends to provider |
| `var_set name value` | Sets variable; Gitea creates only after an update returns 404 |
| `var_delete name` | 2xx or 404 succeeds; other HTTP/transport failures return 2 |
| `ci_run_row ...` | `id status conclusion`; empty only for a valid response with no matching run; errors return 2 |
| `ci_dispatch_deploy` | Dispatches selected workflow on `main`; failure calls `fail` |
| `ci_watch_hint`, `ci_log_hint` | Provider-specific command or URL |
| `ci_diagnose_dump` | Human-readable recent run information, best effort |

Gitea HTTP helpers distinguish two modes: `gitea_api` prints a response body and
fails on HTTP errors; `gitea_api_status` prints the HTTP code for the adapter to
interpret. Connection errors remain nonzero. No credentials are stored in origin
URLs. The public secret API consumes stdin; transport encoding remains internal.

## Failure and workflow selection rules

`ensure_repo` only enters the creation path on status 1 (HTTP 404). Other lookup
failures abort before origin removal or repository creation. GitHub lookup uses
REST status headers, not generic GraphQL errors or error-message text. GitHub
and Gitea may conceal inaccessible private repositories behind HTTP 404; clients
cannot distinguish that response from absence. Explicit 401/403, rate limits,
server failures and connection failures are errors.

Variable deletion is idempotent for 404, but other failures abort CI seeding so
a stale `STAGING_DOMAIN` cannot be silently left enabled. A query failure before
push prevents push/dispatch. Polling errors stop confirmation with a diagnostic;
a successful HTTPS response cannot override them.

Gitea requires **1.25 or newer** and uses `/actions/runs?head_sha=...`, traversing
pages before choosing the newest run matching both commit and workflow path.
`deploy.yml@refs/heads/main` and the `.gitea/workflows/` or `.github/workflows/`
prefixed forms resolve to `deploy.yml`. Run status is the whole workflow status,
not one job's result. Queued/waiting runs stay pending; only completed success
passes. Malformed responses and unknown statuses are errors. A query exceeding
100 pages fails explicitly instead of confirming from an incomplete result.

The bundled image is pinned to the 1.25 series. Existing 1.24 hosts must be
upgraded before bootstrap will proceed. This code change does not upgrade a live
instance. See [Gitea setup](../../docs/gitea.md).

Source contracts: [Gitea 1.25 run response and status conversion](https://github.com/go-gitea/gitea/blob/release/v1.25/services/convert/convert.go#L250),
[Gitea run filtering](https://github.com/go-gitea/gitea/blob/release/v1.25/routers/api/v1/shared/action.go#L119),
and [GitHub CLI API response headers](https://cli.github.com/manual/gh_api).

## Verification

Run `bash test/run.sh`. `test/provider-contract.sh` exercises the public facade
with fake `gh`/`curl`, real JSON encoding and local Git repositories.
`test/provider-runs.sh` exercises run selection and normalization against fixtures.
`test/provider-failures.sh` covers status classification, origin preservation,
pagination, exact run identity, malformed responses and polling errors.
These tests make no live requests. Live provider compatibility is outside this suite.
