# Terraform backend initialization

`scripts/terraform-backend.sh` owns backend identity validation, atomic
`backend.hcl` generation, cache inspection, and Terraform initialization. Its API
is `terraform_backend_init ROOT BUCKET ENDPOINT KEY MODE`. An empty key reads the
literal key from the root's `backend.tf`; tenants pass their explicit state key.
Infrastructure commands require jq to read Terraform's cached JSON metadata.

| Mode and cached backend | Init flag | Behavior |
|---|---|---|
| `bootstrap`, no cache or local backend | `-force-copy` | Migrate local state, accepting Terraform's copy prompts |
| `bootstrap`, S3 backend | `-reconfigure` | Reconnect to the requested bucket, endpoint and key without copying remote state |
| `bootstrap`, malformed or unsupported cache | None | Fail before writing configuration; inspect or migrate explicitly |
| `reconfigure`, any cache | `-reconfigure` | Reconnect without migration; used by all teardown paths |

Bootstrap uses the adapter in `tfstate.sh`. Host and tenant teardown use
`teardown/backend.sh`; Gitea teardown calls the shared helper directly. Creating
the state bucket remains the responsibility of `tfstate.sh`.

Changing a cached remote bucket, key, or endpoint does not migrate its resources.
If a remote-state move is intended, perform that migration explicitly before
bootstrap. No provider cache, workspace selection, or local state file is deleted
by the helper. `TF_DATA_DIR` is honored; relative paths resolve against the
Terraform root, and inspection and initialization use the same absolute path.

Terraform documents that `-force-copy` enables migration and accepts copy prompts,
while `-reconfigure` prevents migration:
[terraform init options](https://developer.hashicorp.com/terraform/cli/commands/init).
The helper propagates init failures and refuses symlink configuration targets.
The configuration remains available for diagnosis if Terraform initialization
fails. It does not provide locking across simultaneous shell invocations.

Run `bash test/terraform-backend.sh` for offline contract tests. The teardown
entry-point suite additionally checks host and tenant callers with mocked cloud
commands. These tests do not exercise real remote state or provision resources.
