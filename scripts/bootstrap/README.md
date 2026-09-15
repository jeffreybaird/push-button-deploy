# Bootstrap implementation modules

`bootstrap.sh` owns argument parsing and the ordered `provision()` sequence.
Source these modules to define operations; call the operations explicitly to
perform work.

- `app.sh`: generate application files, read identity, derive infrastructure
  names, prepare framework releases, and install deployment templates.
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
