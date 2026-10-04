# Bootstrap implementation modules

`bootstrap.sh` owns argument parsing and the ordered `provision()` sequence.
Source these modules to define operations; call the operations explicitly to
perform work.

- `config.sh`: resolve database/staging policy, validate it, and derive required
  tools and credentials. Shared `.env` loading lives in `../config.sh`.
- `app.sh`: generate application files, read identity, derive infrastructure
  names, prepare framework releases, install deployment templates, and adopt
  managed agent docs when an app has no lifecycle manifest.
- `infrastructure.sh`: apply host or tenant Terraform roots and read their
  outputs. Shared state-bucket operations live in `../tfstate.sh`.
- `repository.sh`: create the repository and configure CI secrets/variables
  through `../provider.sh`.
- `../deployment.sh`: trigger and await the expected CI run, then check HTTPS.

`read_app_identity` accepts its stack identity and emits `name|module`.
`prepare_app` accepts the directory, type, framework, database backend and
provider; it scopes those values locally for its file-installation helpers.
Infrastructure and repository operations still share the resolved run context;
their module headers document their inputs and outputs. They must run in the
order shown in `provision()`: resolve identity, create repo, apply infrastructure,
prepare files, seed CI, push, and confirm.

Offline checks live in `test/`. Run `bash test/bootstrap-app.sh` to exercise file
installation across both providers and all supported stack/backend combinations.
Build-tool discovery is stubbed; no cloud services are contacted.

Existing apps skip scaffolding, not preparation. `prepare_app` refreshes selected
deployment templates and installs agent docs only when their manifest is absent.
Use `agent-docs.sh` for updates to already-managed guidance; Terraform files are
seeded separately and preserved on reruns. `commit_push` stages all app changes,
so callers should commit unrelated work before invoking a full bootstrap.

Configuration is loaded before defaults are applied. Flags and interactive input
then feed `resolve_app_config()`: app type/stack resolution, backend normalization,
staging defaults, validation, and dependency derivation. Progress counts are owned
by `provision()` and do not influence policy. `../config.sh` preserves caller
assignment values, including empty strings, and reports overridden key names only.
