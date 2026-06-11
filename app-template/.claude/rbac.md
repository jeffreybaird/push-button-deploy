> **Optional module.** Include if your app has role-based authorization.

# RBAC (Role-Based Access Control)

Load this file when working on user roles, permissions, team management,
or access control enforcement.

> **Baseline:** Phoenix 1.8 · LiveView 1.1 · OTP 27. Scopes = phx.gen.auth default in 1.8 (data boundary). Authentication defaults to magic-link; RBAC roles gate actions on top of scopes.

---

## Scopes + RBAC

Phoenix 1.8 introduces **Scopes** as the phx.gen.auth default ([scopes guide](https://phoenix.hexdocs.pm/scopes.html), [1.8 release](https://www.phoenixframework.org/blog/phoenix-1-8-released)). A scope is a `%MyApp.Accounts.Scope{}` carrying the `user` and — for multi-tenant apps — the `organization`/`account`, plus optional `permissions`/`membership`. It is wired via a `fetch_current_scope_for_user` plug and `on_mount {MyAppWeb.UserAuth, :mount_current_scope}`, and assigned as `current_scope`.

**Scopes and RBAC roles are complementary layers — adopt both:**

| Layer       | Question it answers              | Mechanism                                  |
|-------------|----------------------------------|--------------------------------------------|
| **Scope**   | *Which records can I even see?*   | Data/tenant boundary — query scoping       |
| **RBAC role** | *May I perform this action?*    | Action-level permission — `role_at_least?` |

Context functions take `scope` FIRST, so the data boundary is enforced at the query, not bolted on afterward:

```elixir
# ✅ CORRECT — scope first; the query is bounded to what this scope may see
def get_post!(%Scope{} = scope, id) do
  Post
  |> where(organization_id: ^scope.organization.id)
  |> Repo.get!(id)
end

# ❌ WRONG — relying only on a RequireRole plug, query unbounded
def get_post!(id), do: Repo.get!(Post, id)
```

**Nuance — scopes are a convention, not runtime enforcement.** Security comes from the generators making scoped queries the *default* shape plus developer discipline; there is no automatic runtime check that a query was scoped ([scopes guide](https://phoenix.hexdocs.pm/scopes.html), [Curiosum](https://curiosum.com/blog/phoenix-scopes-authorization-permit-phoenix)). Adopt scopes for query-boundary isolation rather than relying solely on `RequireRole` plugs, and pair every scope-first context function with a `role_at_least?` action check where the action is role-restricted.

phx.gen.auth scaffolds this pattern; legacy `current_membership`/`current_organization` patterns coexist with scopes during migration.

---

## Authentication (phx.gen.auth)

There is no separate accounts doc in this template; authentication conventions live here because RBAC sits on top of them.

`phx.gen.auth` in Phoenix 1.8 defaults to **magic-link (passwordless)** login; email+password is opt-in via user settings ([1.8 release](https://www.phoenixframework.org/blog/phoenix-1-8-released)).

A `require_sudo_mode` plug enforces **recent re-authentication** before sensitive operations. The canonical use is email-change / account settings; billing changes and account deletion are natural extensions of the same plug.

```elixir
# Router — gate sensitive routes behind a fresh-auth window
scope "/app/settings", MyAppWeb.App do
  pipe_through [:browser, :require_authenticated_user, :require_sudo_mode]
  # email change, billing, account deletion, owner transfer …
end
```

- Auth tests exercise token-based magic-link login and sudo windows, organized around scopes.
- **Rate-limit auth endpoints** (magic-link request, login) per-actor — see `scalability.md`.

---

## Roles

If your app needs RBAC, use a flat role model per organization membership.
A user's role is stored on the `Membership` join table between `User` and
`Organization`.

The roles below are illustrative — rename them to fit your domain. Common
sets: `owner/admin/member`, `owner/editor/viewer`, `owner/admin/editor/viewer`.

| Role     | Resources | Team Mgmt | Analytics | Billing | Delete Org |
|----------|-----------|-----------|-----------|---------|------------|
| `owner`  | ✅        | ✅        | ✅        | ✅      | ✅         |
| `admin`  | ✅        | ✅        | ✅        | ✅      | ❌         |
| `editor` | ✅        | ❌        | Read-only | ❌      | ❌         |
| `member` | ❌        | ❌        | ✅        | ❌      | ❌         |

### Role hierarchy

`owner` > `admin` > `editor` > `member`

Higher roles inherit all permissions of lower roles.

### Schema

```elixir
schema "memberships" do
  belongs_to :user, MyApp.Accounts.User
  belongs_to :organization, MyApp.Accounts.Organization
  field :role, Ecto.Enum, values: [:owner, :admin, :editor, :member]
  timestamps()
end
```

### Constraints

- An organization's ownership model is a product decision — single-owner,
  co-owners, or owner-optional are all valid. Pick one for your domain and
  enforce it explicitly (e.g. a DB constraint or a context invariant) rather
  than assuming it.
- A user can be a member of multiple organizations with different roles in each.
- Deleting a membership removes access — the user account itself persists.

### Ownership transfer

Transferring ownership is a separate, audited action — never a plain role update. Wrap it in an `Ecto.Multi` so demoting the old owner and promoting the new one commit atomically ([Ecto.Multi](https://hexdocs.pm/ecto/Ecto.Multi.html)), require sudo-mode (see Authentication), verify the new owner is already a member, and notify via an event (see `architecture-decisions.md`).

```elixir
# ✅ CORRECT — atomic, audited, member-verified
def transfer_ownership(%Scope{} = scope, new_owner_user_id) do
  with :ok <- ensure_owner(scope),
       {:ok, target} <- fetch_membership(scope.organization, new_owner_user_id) do
    Ecto.Multi.new()
    |> Ecto.Multi.update(:demote, demote_changeset(scope.membership))
    |> Ecto.Multi.update(:promote, promote_changeset(target))
    |> Repo.transaction()
    |> case do
      {:ok, %{promote: m}} ->
        MyApp.Events.broadcast(scope, {:ownership_transferred, m})
        {:ok, m}

      {:error, _step, changeset, _} ->
        {:error, :validation, changeset}
    end
  end
end

# ❌ WRONG — non-atomic, unaudited, no sudo/membership check
def transfer_ownership(org, user_id) do
  update_role(org.owner, :admin)
  update_role(user_id, :owner)
end
```

The route invoking this must sit behind `require_sudo_mode` ([1.8 release](https://www.phoenixframework.org/blog/phoenix-1-8-released)).

---

## Platform-Level (Super Admin) Role

For platform operators who need cross-tenant access, add an `is_super_admin`
boolean to the `User` schema. Super admins bypass per-tenant RBAC checks in
designated admin contexts only — never in tenant-scoped code paths.

```elixir
# In User schema
field :is_super_admin, :boolean, default: false
```

### Super admin + Scopes

The `is_super_admin` flag does two distinct things, and only the first is automatic ([scopes guide](https://phoenix.hexdocs.pm/scopes.html)):

1. **Gates entry to `/admin` routes** (via a plug / on_mount hook).
2. **Grants a broadened scope** for functions *explicitly marked* cross-tenant.

```elixir
# ✅ CORRECT — broadened scope only where a function opts in explicitly
def list_all_orgs(%Scope{user: %{is_super_admin: true}}), do: Repo.all(Organization)

# ❌ WRONG — a tenant-scoped function silently changing behavior on the flag
def get_post!(%Scope{} = scope, id) do
  if scope.user.is_super_admin, do: Repo.get!(Post, id), else: scoped_get!(scope, id)
end
```

Tenant-scoped functions must keep their boundary regardless of the flag; cross-tenant access is opt-in per function, never an implicit override.

---

## Enforcement

### Plug: `RequireRole`

For controller routes, keep the `RequireRole` plug — but source the membership
from `current_scope` so the role check and the query boundary agree. For
LiveView route access, use `on_mount` hooks instead of a plug (see below);
`RequireRole` is a controller-pipeline tool ([scopes guide](https://phoenix.hexdocs.pm/scopes.html)).

```elixir
# In router — applies to all routes in this scope
scope "/app/settings", MyAppWeb.App do
  pipe_through [:browser, :require_authenticated_user, :require_role_admin]
  # ...
end

# The plug — reads membership from the scope, not a separate assign
defmodule MyAppWeb.Plugs.RequireRole do
  import Plug.Conn
  import Phoenix.Controller, only: [put_flash: 3, redirect: 2]

  def init(opts), do: opts

  def call(conn, minimum_role: role) do
    membership = conn.assigns.current_scope.membership

    if Accounts.role_at_least?(membership, role) do
      conn
    else
      conn
      |> put_flash(:error, "You don't have permission to access this page.")
      |> redirect(to: "/app")
      |> halt()
    end
  end
end
```

### LiveView Authorization (on_mount)

LiveView authorization is **two layers**, and you need both ([scopes guide](https://phoenix.hexdocs.pm/scopes.html), [LiveView docs](https://hexdocs.pm/phoenix_live_view/Phoenix.LiveView.html)):

| Layer            | When it runs                    | What it gates                         |
|------------------|---------------------------------|---------------------------------------|
| `mount` / `on_mount` | once, at page load (via `live_session` hooks from phx.gen.auth) | **page access** — may this scope open this LiveView at all |
| `handle_event`   | every event over the live connection | **action access** — may this scope do this specific thing |

```elixir
# Page-access layer — live_session + on_mount, scaffolded by phx.gen.auth
live_session :admin,
  on_mount: [{MyAppWeb.UserAuth, :mount_current_scope}, {MyAppWeb.UserAuth, :require_admin}] do
  live "/app/settings", SettingsLive
end
```

**Per-event checks in `handle_event` are REQUIRED, not a fallback.** Events arrive over a long-lived socket *after* mount, so each one must be re-verified server-side — `on_mount` does NOT replace them. A user who legitimately mounted a page can still send an event they aren't authorized to perform.

(`handle_params` is not a co-equal third pillar; treat it only as a situational re-auth point when a live-patch swaps the resource being viewed.)

In `handle_event` callbacks, check roles before performing the action.
Use the `Accounts.has_role?/2` or `Accounts.role_at_least?/2` helper.

```elixir
# ✅ CORRECT — check before acting
def handle_event("delete_resource", %{"id" => id}, socket) do
  if Accounts.role_at_least?(socket.assigns.current_membership, :editor) do
    {:ok, _} = Resources.delete(socket.assigns.organization, id)
    {:noreply, assign(socket, items: Resources.list(socket.assigns.organization))}
  else
    {:noreply, put_flash(socket, :error, "Insufficient permissions")}
  end
end

# ❌ WRONG — no role check
def handle_event("delete_resource", %{"id" => id}, socket) do
  {:ok, _} = Resources.delete(socket.assigns.organization, id)
  {:noreply, assign(socket, items: Resources.list(socket.assigns.organization))}
end
```

### Never check roles by string or atom comparison

Always use the `Accounts` context functions for role checks. Never compare
role atoms directly.

```elixir
# ✅ CORRECT
Accounts.role_at_least?(membership, :admin)

# ❌ WRONG
membership.role == :admin || membership.role == :owner
```

---

## Role Helper Functions

These belong in the `Accounts` context:

```elixir
@role_hierarchy [:member, :editor, :admin, :owner]

@doc """
Returns true if the membership's role is at least the given minimum role.

    iex> membership = %Membership{role: :admin}
    iex> Accounts.role_at_least?(membership, :editor)
    true

    iex> membership = %Membership{role: :editor}
    iex> Accounts.role_at_least?(membership, :admin)
    false
"""
def role_at_least?(%Membership{role: role}, minimum_role) do
  role_index(role) >= role_index(minimum_role)
end

defp role_index(role) do
  Enum.find_index(@role_hierarchy, &(&1 == role)) || -1
end
```

`role_at_least?` is appropriate for **flat hierarchies**. Reach for a policy
library (below) when you need field redaction, plan/feature gates, or nested
role hierarchies ([LetMe](https://let-me.hexdocs.pm/readme.html)).

---

## Authorization Approach

The real smell is **duplicating the same rule across controllers and LiveView
events**. When one rule lives in three places, it drifts. Choosing a policy
abstraction is a *choice*, not a mandate — Elixir authz-library adoption is far
less universal than Rails', and plain context-function checks are sufficient
for many apps.

**Escalation ladder — start at the top, move down only when you hit the trigger:**

1. **Plain context-function checks** (idiomatic, your default). The existing
   `role_at_least?` approach is fine for flat hierarchies. *Consider moving down if
   rules duplicate across surfaces, grow complex, or need field redaction /
   nested hierarchies.*
2. **Bodyguard** (community option) — policy callbacks + manual query scoping.
3. **LetMe** (community option) — compile-time policy DSL, scoped queries, field
   redaction. Depends on Spek, so **not** zero-dependency and **not** a de-facto
   standard ([LetMe readme](https://let-me.hexdocs.pm/readme.html),
   [woylie/let_me](https://github.com/woylie/let_me)).
4. **Permit** (community option) — compiles rules to Ecto queries, with
   Phoenix/LiveView integration ([Curiosum](https://curiosum.com/blog/phoenix-scopes-authorization-permit-phoenix)).

```elixir
# deps — pick at most one; use ~> ranges, not pinned patch versions
{:bodyguard, "~> 2.4"}
{:let_me, "~> 1.0"}
{:permit, "~> 0.2"}
```

Whichever you pick, keep it as the *single* source for a rule so controllers and
LiveView events call the same policy.

---

## Testing RBAC

Every action that is role-restricted must have tests for:
1. A user with sufficient role — action succeeds
2. A user with insufficient role — action is denied
3. A user from a different organization — action is denied (tenant isolation)

```elixir
describe "delete_resource (editor+ required)" do
  test "editor can delete a resource" do
    org = insert(:organization)
    membership = insert(:membership, organization: org, role: :editor)
    resource = insert(:resource, organization: org)

    {:ok, view, _} = live(conn_for(membership), "/app/content")
    view |> element("[phx-click='delete_resource'][phx-value-id='#{resource.id}']") |> render_click()

    assert Resources.get(org, resource.id) == nil
  end

  test "member cannot delete a resource" do
    org = insert(:organization)
    membership = insert(:membership, organization: org, role: :member)
    resource = insert(:resource, organization: org)

    {:ok, view, _} = live(conn_for(membership), "/app/content")
    # The delete button should not be rendered, or clicking it should flash an error
    refute has_element?(view, "[phx-click='delete_resource']")
  end
end
```

### Scope fixtures (Phoenix 1.8)

When a scope is configured — the default for new apps — build `%Scope{}` from a
user + membership + org and pass it to context functions, then assert that one
scope cannot reach another's data.

In Phoenix 1.8, `user_scope_fixture/0` lives in the module named by the
`:scope` config's `test_data_fixture` key (typically `MyApp.AccountsFixtures`,
scaffolded by phx.gen.auth) and is auto-imported into your tests;
`register_and_log_in_user` is a setup helper ([1.8 release](https://www.phoenixframework.org/blog/phoenix-1-8-released),
[scopes guide](https://hexdocs.pm/phoenix/scopes.html)).

```elixir
import MyApp.AccountsFixtures  # auto-imported scope/user fixtures

describe "scope isolation" do
  setup :register_and_log_in_user

  test "a scope cannot read another scope's records" do
    scope_a = user_scope_fixture()
    scope_b = user_scope_fixture()

    {:ok, post_a} = Posts.create_post(scope_a, %{title: "A"})

    # ✅ owning scope sees it
    assert Posts.get_post!(scope_a, post_a.id).id == post_a.id

    # ✅ foreign scope is bounded out — scoped get raises, never leaks
    assert_raise Ecto.NoResultsError, fn ->
      Posts.get_post!(scope_b, post_a.id)
    end
  end
end
```

---

## Cross-references

- `multi-tenancy.md` — tenant scoping, query patterns, ensuring org isolation
- `external-service-integration.md` — integrating external providers (payment, media, etc.)
- `architecture-decisions.md` — audit logging, error tuples, feature flags
- `testing.md` — factory patterns, conn helpers, full test category requirements
