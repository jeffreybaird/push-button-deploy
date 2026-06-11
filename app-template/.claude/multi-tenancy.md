> **Optional module.** Include only if your app is multi-tenant (shared-schema). Single-tenant apps can skip this.

# Multi-Tenancy Rules

> **Baseline:** Phoenix 1.8 · LiveView 1.1 · Ecto 3.13+ · OTP 27. Scopes = phx.gen.auth default in 1.8; shared-schema org_id scoping is the default multi-tenancy model.

Load this file when working on any feature that touches tenant-scoped data.

---

## Core Principle

If your app is multi-tenant, it likely uses a shared-schema approach: every tenant
shares the same Postgres database and the same tables. Isolation is enforced at the
application layer, not the database layer.

The tenant model in this guide is called `Organization`, but your app may name it
`Account`, `Workspace`, `Tenant`, or similar — apply the same rules regardless of
the name.

### Isolation strategy — pick by isolation need

Shared-schema with an `organization_id` foreign key is the **default**, and the
filter is threaded through a Phoenix 1.8 `Scope` (see "Scopes" below). Reserve
heavier strategies for strong-isolation or compliance requirements — they cost
operational complexity (migrations per prefix, connection juggling, separate
backups).

| Strategy | When to use | Trade-off |
|---|---|---|
| **FK scoping (`organization_id`)** — *default* | Almost all SaaS apps; thread via `Scope` ([Ecto: multi-tenancy with FKs](https://ecto.hexdocs.pm/multi-tenancy-with-foreign-keys.html)) | Isolation is app-layer; a missed `where` leaks data |
| **Query prefixes (Postgres schemas)** | Stronger isolation, per-tenant schema, still one DB ([Ecto: query prefixes](https://ecto.hexdocs.pm/multi-tenancy-with-query-prefixes.html)) | Migrations run per prefix; cross-tenant queries awkward |
| **Triplex** | Schema-per-tenant with a managed library ([Triplex](https://github.com/ateliware/triplex)) | Same prefix costs + library coupling; *one valid option*, not a mandate |
| **Separate database per tenant** | Regulatory hard isolation, large enterprise tenants | Highest ops cost; connection + migration fan-out |

> Most apps should not move past row #1. If you think you need prefixes, confirm the
> driver is a compliance/contractual requirement, not a hypothetical.

---

## Schema Rules

### Every tenant-scoped table has `organization_id`

No exceptions. If data belongs to a tenant, it has an `organization_id` foreign key
with an index. The only tables without it are `organizations` itself and
system-level tables (e.g. Oban jobs, global feature flags).

```elixir
# ✅ CORRECT — every tenant table
schema "posts" do
  belongs_to :organization, MyApp.Accounts.Organization
  field :title, :string
  # ...
  timestamps()
end

def changeset(post, attrs) do
  post
  |> cast(attrs, [:title, :organization_id, ...])
  |> validate_required([:title, :organization_id])
  |> foreign_key_constraint(:organization_id)
end
```

### Composite unique constraints include `organization_id`

Any uniqueness constraint (e.g. resource slug, plan name) must be scoped to the
organization. A slug that's unique globally is wrong — it should be unique per-org.

```elixir
# ✅ CORRECT
|> unique_constraint([:slug, :organization_id])

# ❌ WRONG — globally unique slug prevents two orgs from using the same slug
|> unique_constraint([:slug])
```

### Migration pattern

```elixir
def change do
  create table(:posts) do
    add :organization_id, references(:organizations, on_delete: :delete_all), null: false
    add :title, :string, null: false
    # ...
    timestamps()
  end

  create index(:posts, [:organization_id])
  create unique_index(:posts, [:slug, :organization_id])
end
```

Always use `on_delete: :delete_all` on the organization FK so that deleting an
organization cascades cleanly. Never use `:nothing` or `:nilify_all` — orphaned
tenant data is a data integrity bug.

---

## Scopes — the Phoenix 1.8 default for tenant data access

Phoenix 1.8's `phx.gen.auth` generates a **Scope** struct — a plain struct carrying
request context (the `user`, and for multi-tenant apps the `organization`/`account`)
([Phoenix Scopes](https://phoenix.hexdocs.pm/scopes.html),
[Phoenix 1.8 release](https://www.phoenixframework.org/blog/phoenix-1-8-released)).
Scopes are the modern, preferred way to thread the tenant boundary so queries are
constrained **by default** rather than relying on every author to remember a `where`
clause. This directly targets OWASP Broken Access Control: a context function takes
the scope as its first argument and can only see records the scope permits.

> **Scopes are DATA BOUNDARIES, not authorization.** A scope answers "which records
> are visible," never "which actions are permitted." See "Scoping vs Authorization"
> below.

### The generated Scope and its wiring

`phx.gen.auth` generates a `for_user/1` constructor. For multi-tenancy, extend the
struct with the tenant (`organization` / `org_id`) so every scoped query carries it:

```elixir
defmodule MyApp.Accounts.Scope do
  alias MyApp.Accounts.{User, Organization}

  defstruct user: nil, organization: nil, org_id: nil

  @doc "Build a scope from a user (phx.gen.auth default)."
  def for_user(%User{} = user), do: %__MODULE__{user: user}
  def for_user(nil), do: nil

  @doc "Attach the resolved tenant to an existing scope."
  def put_organization(%__MODULE__{} = scope, %Organization{} = org) do
    %{scope | organization: org, org_id: org.id}
  end
end
```

Wiring (generated by `phx.gen.auth`, extend the org resolution into it):

```elixir
# router.ex — controllers
pipeline :browser do
  # ...
  plug :fetch_current_scope_for_user
end

# LiveView — assigns current_scope via the pre-defined hook
live_session :authenticated,
  on_mount: [{MyAppWeb.UserAuth, :mount_current_scope}] do
  live "/", DashboardLive
end
```

Both the plug and the on_mount hook assign `current_scope` (`conn.assigns.current_scope`
/ `socket.assigns.current_scope`).

### Generators thread scope — but only with a configured default scope

Scope-aware generation is **not unconditional**. The generators build scoped resources
(threading `scope` as the first argument) only when a default scope is configured under
your OTP app ([Phoenix Scopes](https://phoenix.hexdocs.pm/scopes.html)):

```elixir
# config/config.exs
config :my_app, :scopes,
  user: [
    default: true,            # gates scoped generation — without it, gen is unscoped
    module: MyApp.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:user, :id]
    # ...
  ]
```

Without a configured default scope, `mix phx.gen.*` produces **unscoped** functions and
you wire scoping in yourself. Scopes are removable at generation time with `--no-scope`.

### Scope-first context functions

```elixir
# ✅ PREFERRED (1.8+) — scope is the first arg; query constrained by default
def list_posts(%Scope{org_id: org_id}, opts \\ []) do
  Post
  |> where(organization_id: ^org_id)
  |> order_by(desc: :inserted_at)
  |> MyApp.Repo.all()
end

def get_post!(%Scope{org_id: org_id}, id) do
  Post
  |> where(organization_id: ^org_id, id: ^id)
  |> MyApp.Repo.one!()
end
```

### Incremental adoption — both patterns coexist

Adopting Scopes is incremental. The explicit `where(organization_id: ^id)` mechanism
(below) and the Scope pattern coexist; legacy `org_id`/`%Organization{}`-first
functions can stay until migrated. **On 1.8+, prefer Scopes for new code.** Migrate a
function by changing its first argument from `%Organization{}`/`org_id` to `%Scope{}`
and reading `scope.org_id` — the body's `where` clause is unchanged.

---

## Query Rules

### All context functions scope to organization

The explicit/legacy mechanism: context functions that return tenant data accept an
`%Organization{}` or `organization_id` as the first argument and apply the
`organization_id` filter manually. This still works and remains valid for Phoenix 1.7
apps or where you want fully explicit control — but on 1.8+ prefer threading a `Scope`
(see "Scopes" above), which makes the filter the default rather than a per-function
responsibility.

```elixir
# ✅ CORRECT — organization scopes the query
def list_posts(%Organization{id: org_id}) do
  Post
  |> where(organization_id: ^org_id)
  |> order_by(desc: :inserted_at)
  |> MyApp.Repo.all()
end

def get_post(%Organization{id: org_id}, post_id) do
  Post
  |> where(organization_id: ^org_id, id: ^post_id)
  |> MyApp.Repo.one()
end

# ❌ WRONG — returns data across all tenants
def list_posts do
  MyApp.Repo.all(Post)
end

# ❌ WRONG — fetches by ID without org scoping (data leak risk)
def get_post(post_id) do
  MyApp.Repo.get(Post, post_id)
end
```

### Never expose unscoped queries

The only functions that may query across tenants are explicit system/admin
functions, clearly namespaced and documented:

```elixir
# Acceptable — clearly marked as system-level
defmodule MyApp.Admin do
  @doc "System-level: returns all organizations. Not for tenant use."
  def list_all_organizations do
    MyApp.Repo.all(Organization)
  end
end
```

### Advanced: automatic scoping with `prepare_query`

For apps that can't use Scopes (Phoenix 1.7, or a deliberate choice for centralized
explicit control), Ecto 3.10+ can inject the `org_id` filter into **every** query via
a `Repo` that implements `prepare_query/3` and `default_options/1`
([Ecto: multi-tenancy with FKs](https://ecto.hexdocs.pm/multi-tenancy-with-foreign-keys.html)).
The `org_id` is pulled from the process dictionary (set per request/job), with a
`skip_org_id: true` escape hatch for the rare cross-tenant query:

```elixir
defmodule MyApp.Repo do
  use Ecto.Repo, otp_app: :my_app, adapter: Ecto.Adapters.Postgres

  require Ecto.Query

  @impl true
  def default_options(_op), do: [org_id: Process.get(:org_id)]

  @impl true
  def prepare_query(_op, query, opts) do
    cond do
      opts[:skip_org_id] || opts[:schema_migration] ->
        {query, opts}

      org_id = opts[:org_id] ->
        {Ecto.Query.where(query, org_id: ^org_id), opts}

      true ->
        raise "expected org_id or :skip_org_id, got: #{inspect(opts)}"
    end
  end
end
```

Use **composite foreign keys** (`[:org_id, :parent_id]` referencing `[:org_id, :id]`)
so a child row can never reference a parent in a different org. On Phoenix 1.8+ prefer
Scopes; `prepare_query` is the explicit alternative when Scopes aren't available.

### Tenant-driven side effects need a stable idempotency key

If a context function triggers a webhook, export, or other external unit of work, store
a stable idempotency key **with** that unit of work (scoped to the org) and reuse it
across Oban retries — never generate a fresh key on retry, or a transient failure
becomes a duplicate delivery
([webhook idempotency at scale](https://dev.to/whoffagents/webhook-processing-at-scale-idempotency-signature-verification-and-async-queues-45b3)).
The key (e.g. `"#{org_id}:#{resource_id}:#{event}"`) goes in the Oban job args
alongside the scope id, so the worker is safe to run more than once.

---

## Tenant Resolution

### Plug: `SetOrganization`

Tenant is resolved from the request in this order:

1. **Custom domain** — look up `organizations` by `custom_domain` field
2. **Subdomain** — extract subdomain from host, look up by `slug`
3. **Fallback** — 404 if no tenant is resolved

**Phoenix 1.7 / legacy:** the resolved `%Organization{}` is placed in
`conn.assigns.organization` and propagated to `socket.assigns.organization` in
LiveView `on_mount`.

**Phoenix 1.8+:** the same resolution becomes part of **Scope construction**
([Phoenix Scopes](https://phoenix.hexdocs.pm/scopes.html)). The org-resolution plug
runs after `fetch_current_scope_for_user` and folds the tenant into the scope rather
than a separate assign:

```elixir
# plug — resolve org, then attach to the already-fetched scope
def call(conn, _opts) do
  org = resolve_organization!(conn)
  scope = Scope.put_organization(conn.assigns.current_scope, org)
  assign(conn, :current_scope, scope)
end
```

Both patterns coexist during incremental migration; new code reads the tenant from
`current_scope`, not a standalone `organization` assign.

### LiveView mount

Every LiveView that renders tenant-scoped content must read `organization` from
socket assigns. The `on_mount` hook handles this — individual LiveViews do not
resolve the tenant themselves.

```elixir
# In the router
live_session :authenticated, on_mount: [{MyAppWeb.Hooks.AssignOrganization, :assign}] do
  live "/", DashboardLive
  live "/resources/:id", ResourceLive
end
```

(On 1.8+ this hook is replaced by `{MyAppWeb.UserAuth, :mount_current_scope}`, which
assigns `current_scope` — see "Scopes" above.)

---

## Scoping vs Authorization

These are **two different concerns** and conflating them is a security bug
([Phoenix Scopes](https://phoenix.hexdocs.pm/scopes.html),
[Curiosum: scopes & authorization](https://curiosum.com/blog/phoenix-scopes-authorization-permit-phoenix)):

| Concern | Question it answers | Mechanism |
|---|---|---|
| **Scoping** | *Which records are visible to this request?* | `Scope` / `org_id` filter |
| **Authorization** | *Which actions may this user perform on them?* | policy library |

A user with a perfectly valid scope can still lack permission to delete, export, or
edit a record inside that scope. Scoping narrows the rows; authorization gates the
verbs.

```elixir
# ❌ WRONG — scope check treated as the authorization check
def delete_post(%Scope{org_id: org_id} = scope, id) do
  post = get_post!(scope, id)   # scoped, yes — but can THIS user delete?
  Repo.delete(post)
end

# ✅ CORRECT — scope for visibility, policy for the action
def delete_post(%Scope{} = scope, id) do
  post = get_post!(scope, id)

  with :ok <- MyApp.Policy.authorize(:delete_post, scope.user, post) do
    Repo.delete(post)
  end
end
```

Pair scopes with an authorization library — **LetMe**, **Bodyguard**, or **Permit**
are all valid options (your choice). LetMe additionally provides authorized **query
scopes** and **field redaction**, useful when row visibility and field visibility
differ within the same tenant.

---

## Atomic Tenant Setup with `Ecto.Multi`

Provisioning a new tenant usually means creating several rows that must all succeed or
all fail — the org, a default plan/subscription, and an initial owner role. Do it in
one transaction with `Ecto.Multi` and named steps ([Ecto.Multi](https://hexdocs.pm/ecto/Ecto.Multi.html)):

```elixir
def provision_organization(attrs, owner) do
  Ecto.Multi.new()
  |> Ecto.Multi.insert(:org, Organization.changeset(%Organization{}, attrs))
  |> Ecto.Multi.insert(:plan, fn %{org: org} ->
    Plan.default_changeset(org)
  end)
  |> Ecto.Multi.insert(:role, fn %{org: org} ->
    Membership.owner_changeset(org, owner)
  end)
  |> MyApp.Repo.transaction()
  |> case do
    {:ok, %{org: org}} ->
      # Side effects happen AFTER commit — see below.
      MyApp.Events.broadcast({:organization_provisioned, org})
      {:ok, org}

    {:error, :org, changeset, _changes} ->
      {:error, :validation, changeset}

    {:error, _failed_op, changeset, _changes} ->
      {:error, :validation, changeset}
  end
end
```

`Repo.transaction/1` returns `{:error, failed_operation, failed_value, changes_so_far}`
on failure — map that to the project's tagged tuples (`{:error, :validation, changeset}`),
never a bare `{:error, changeset}`. `Repo.transact/2` is the equivalent helper when each
step is a plain function returning `{:ok, _}` / `{:error, _}`.

> **Do NOT put the audit entry inside the `Multi`.** Per CLAUDE.md "Emit Events, Don't
> Inline Side Effects," the audit record, webhooks, and notifications are side effects.
> Broadcast the event **after** the transaction commits and let `AuditSubscriber` record
> it — keep the Multi to durable provisioning rows only.

---

## Test Isolation

### Every test creates its own organization

Never rely on a shared/global organization across tests. Each test case inserts
its own org via the factory.

```elixir
test "lists only posts for the given organization" do
  org_a = insert(:organization)
  org_b = insert(:organization)
  post_a = insert(:post, organization: org_a)
  _post_b = insert(:post, organization: org_b)

  result = Content.list_posts(org_a)
  assert length(result) == 1
  assert hd(result).id == post_a.id
end
```

### Always test cross-tenant isolation

For every context function that reads data, include a test that verifies org A
cannot see org B's data. This is not optional — it is the most important category
of test in a multi-tenant system.
