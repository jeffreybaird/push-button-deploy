# Runner-side deployment helpers

Bootstrap copies the shell scripts in this directory into generated service and
static-site repositories. Run them from the application repository root.

- `configure-ssh.sh`: install `SSH_PRIVATE_KEY` and scan `HOST` into known hosts.
- `runtime-env.sh postgres|sqlite production|staging [destination]`: write a
  private runtime env file from workflow environment values. `APP_ENV` remains
  appended verbatim. Staging SQLite omits the production backup fields.
- `remote.sh`: named SSH/SCP operations. `HOST` names the destination;
  `STACK_DIR` and `APP_SLUG` identify the app. `prepare-edge` also needs `DOMAIN`;
  `pull-image` needs `DOCR_TOKEN`. Secrets are supplied as environment data.

The workflow owns the sequence: upload files, prepare the edge, authenticate and
pull, migrate, then swap. Rollback omits migrations. Static publication and PR
slot ownership remain explicit in their workflows.

Production replaces shared edge templates. `upload-staging-edge` seeds missing
shared files and uploads an environment-specific route template; it preserves
existing production edge configuration. Staging cleanup retains inline SSH setup
because its historical base checkout may predate these helper scripts.

To adopt an updated workflow in an existing application, copy `deploy/ci/*.sh`
along with it, or re-run bootstrap to install both. The helpers require Bash,
SSH/SCP, and standard runner utilities, with no provider-specific API dependency.

Offline checks: `bash test/workflow-scripts.sh`, `ruby test/workflow-templates.rb`
and `bash test/bootstrap-app.sh` from the tooling repository root.
