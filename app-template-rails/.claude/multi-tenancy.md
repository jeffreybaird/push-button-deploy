# Optional multi-tenancy

No tenants or scope objects are installed in the Notes scaffold. Add these only
for an application requirement. The supported deployment still backs up one
SQLite file; database-per-tenant or separate schemas are not an automatic option.

Prefer shared tables with indexed, non-null tenant foreign keys when introducing
tenants. Resolve the authenticated membership once at the request boundary.
Pass an explicit scope containing the actor and tenant to domain operations;
never derive authority from a submitted tenant ID or a global default scope.

Start reads and writes from authorized associations such as `scope.account.notes.kept`.
Apply the boundary to lists, individual lookups, mutation targets, exports,
background jobs and file references. A missing tenant must fail closed on routes
that require one. Scope determines visible rows; a separate policy authorizes
verbs. `Current` correlation state is neither boundary nor permission by itself.

Enforce tenant uniqueness with composite database indexes and model validation.
Namespace caches and optional event channels by tenant; authorize subscriptions.
Jobs must carry identifiers and re-establish their scope rather than inheriting
request state. Keep transactions bounded so one tenant cannot monopolize SQLite's
single writer.

Each read and write path needs a test proving tenant A cannot reach tenant B's
record, including forged IDs and client-supplied tenant attributes. Explicit
cross-tenant admin operations require their own authorization and audit tests.
When implementing export, cover every tenant table, including archived records;
retention and erasure are deliberate product requirements, not blanket promises.
