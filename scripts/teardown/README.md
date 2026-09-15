# Teardown planning and execution

`teardown.sh` resolves local identity and resource ownership, builds an ordered
plan, displays it, checks prerequisites, requests the existing confirmation, and
executes exactly those planned operations. `--plan` stops after displaying the
plan; it makes no remote requests and needs no cloud credentials. It is a scope
preview, not a Terraform resource diff or a guarantee that remote resources exist.

| Module | Responsibility |
|---|---|
| `context.sh` | Arguments, app identity, owned roots, requirements |
| `environment.sh` | Recorded tenant backend identity and Terraform environment |
| `plan.sh` | Ordered operations, labels, confirmation, dispatch |
| `operations.sh` | Individual host, tenant, registry and cache operations |
| `guards.sh` | Temporary lifecycle overrides and restoration |
| `backend.sh` | Remote backend initialization (shared separately in the next refactor) |

Repository-only apps never select Terraform roots. Tenants select only their
recorded tenant root and require the state key to match the project. They never
plan host droplet, persistent-root or state-bucket destruction. Host state-bucket
destruction follows app/persistent teardown. Static sites never plan image
repository deletion. Code-host deletion requires `--delete-repo`.

Tenant cleanup failures now stop before DNS/state destruction so cleanup can be
retried with the original state intact. Registry query errors and Terraform
failures also stop subsequent steps. This is sequential execution, not rollback:
previous successful deletes cannot be undone.

The EXIT/INT/TERM handlers remove generated overrides and restore preexisting
override files, including paths with spaces. Restoration failures retain backups
and return failure. SIGKILL or power loss cannot run shell cleanup handlers.

Verification: `bash test/teardown.sh` runs the real entry point against temporary
apps and fake Terraform, SSH, registry and code-host commands. It covers scope,
ordering, confirmation rejection, failure/interruption cleanup and tenant
isolation. No real infrastructure is touched.
