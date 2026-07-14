# Testing

Load this file when writing tests, setting up test infrastructure, or reviewing
test coverage.

> **Baseline:** Phoenix 1.8 · LiveView 1.1 (LazyHTML test engine) · ExUnit · Scopes default. Test progression: unit+mocks → LiveViewTest → PhoenixTest (cross-page) → Wallaby/Playwright (JS). Major user-facing features additionally get Cucumberex acceptance features (Gherkin `.feature` files run via `mix cucumber`).

---

## Test Structure

```
features/                             # Cucumberex acceptance tests (major features)
├── signup.feature
├── checkout.feature
├── step_definitions/
│   ├── signup_steps.ex
│   └── checkout_steps.ex
└── support/
    └── env.ex                        # world factory, sandbox hooks
test/
├── my_app/                           # Unit & context tests
│   ├── accounts/
│   ├── content/
│   ├── billing/
│   ├── catalog/
│   ├── analytics/
│   └── workers/                      # Oban worker tests
├── my_app_web/
│   ├── live/                         # LiveViewTest integration tests
│   │   ├── admin/
│   │   └── public/
│   ├── controllers/
│   └── e2e/                          # Wallaby browser tests (tagged :e2e)
│       ├── user_workflow_test.exs
│       ├── admin_dashboard_test.exs
│       └── payment_checkout_test.exs
├── support/
│   ├── conn_case.ex
│   ├── data_case.ex
│   ├── wallaby_case.ex               # Wallaby test case template
│   ├── factory.ex                    # ExMachina factory
│   └── mocks.ex                      # Mox mock definitions
└── fixtures/
    └── webhooks/
        ├── payment_succeeded.json
        └── media_asset_ready.json
```

---

## The E2E Rule

**Every user-facing feature must have end-to-end test coverage of every
possible user pathway.** This is not optional. A feature is not done until its
pathways are tested.

### What "every possible user pathway" means

For a given feature, enumerate every way a user can interact with it and every
outcome that can result. Each pathway gets a test. Examples:

**Feature: "Save" button on a resource page**
- Authenticated user clicks button → resource saved, success state shown
- Authenticated user clicks button on already-saved resource → resource removed
- Unauthenticated user clicks button → redirected to login
- Authenticated user without required plan clicks button → redirected to upgrade
- Button renders in "saved" state when resource is already saved on page load

**Feature: Admin resource upload**
- Admin uploads valid resource → resource created, background job triggered, success flash
- Admin uploads with missing title → validation error displayed
- Editor role uploads → succeeds (editor has content permissions)
- Viewer/support role attempts upload → denied
- Upload from a different organization's admin → cannot access (if multi-tenant)

### Prefer LiveViewTest over Wallaby

LiveViewTest is the default tool for E2E pathway coverage. It is fast, async,
runs without a browser, and covers the vast majority of user interactions.

**Use LiveViewTest for:**
- Page rendering and conditional content
- Form submission (valid and invalid)
- `phx-click`, `phx-submit`, `phx-change` events
- Navigation between pages
- Flash messages
- Multi-tenant isolation (if your app is multi-tenant)
- RBAC enforcement
- Subscription/plan gating
- Real-time updates via PubSub

### PhoenixTest for cross-page flows

When a flow spans both LiveView **and** static (dead) pages — e.g. a marketing
landing page → sign-up LiveView → confirmation controller page — raw
`LiveViewTest` + `Phoenix.ConnTest` forces you to switch APIs mid-test and assert
with brittle `=~` checks. [PhoenixTest](https://github.com/germsvel/phoenix_test)
(`germsvel/phoenix_test`, `~> 0.11`, Capybara-inspired) is the most popular
community library for this: one API (`visit`, `click_link`, `click_button`,
`fill_in`, `submit`, `assert_has`, `refute_has`) that auto-switches between the
LiveView and static drivers, follows redirects, and produces clearer failure
messages than `=~`. Strong community recommendation, not a Phoenix-core
requirement.

```elixir
# test/my_app_web/features/signup_flow_test.exs
use MyAppWeb.ConnCase, async: true
import PhoenixTest

test "visitor signs up across static + LiveView pages", %{conn: conn} do
  conn
  |> visit(~p"/")                         # static landing page
  |> click_link("Get started")            # → sign-up LiveView
  |> fill_in("Email", with: "new@example.com")
  |> fill_in("Password", with: "supers3cret!")
  |> submit()                             # follows redirect to confirmation
  |> assert_has("[data-test=\"signup-confirmation\"]")
end
```

PhoenixTest does **not** execute JavaScript by default. For real JS, use its
Playwright driver ([docs](https://hexdocs.pm/phoenix_test/PhoenixTest.html)) or
escalate to Wallaby — see the decision table below. Background and rationale:
[ElixirForum announcement](https://elixirforum.com/t/phoenixtest-a-unified-way-of-writing-feature-tests-for-liveview-and-static-pages/61387).

### Choosing a tool: decision table

| Scenario                                            | Tool             |
|-----------------------------------------------------|------------------|
| Single LiveView: events, forms, conditional render  | LiveViewTest     |
| Single dead/static page or controller               | `Phoenix.ConnTest`|
| Flow spanning LiveView **and** static pages          | PhoenixTest      |
| Real JS execution (hooks, drag-drop, redirects)     | Wallaby/Playwright|
| CSS/visual rendering verification                   | Wallaby/Playwright|

Progression ladder (escalate only when the rung below cannot cover the case):
unit+mocks → LiveViewTest → PhoenixTest (cross-page) → Wallaby/Playwright (JS).

**Use Wallaby ONLY for things LiveViewTest cannot cover:**
- TypeScript hooks actually executing (e.g. a media player mounts and plays)
- JavaScript-driven interactions (drag-and-drop, sortable lists)
- Real payment provider Checkout redirect → return flow
- CSS/visual rendering verification
- Flows that depend on client-side JS state

### Wallaby tests are tagged and excluded by default

All Wallaby test modules must have `@moduletag :e2e`. They are excluded from
`mix test` by default and only run in CI or when explicitly included:

```bash
# Normal development
mix test                    # Runs everything EXCEPT :e2e

# Run only E2E
mix test --only e2e         # Requires Chrome + ChromeDriver

# CI runs both as separate jobs
```

---

## Acceptance Tests: Cucumberex for Major User-Facing Features

[Cucumberex](https://hexdocs.pm/cucumberex) (`{:cucumberex, "~> 0.2"}`, injected
as a default dep) runs Gherkin `.feature` files via `mix cucumber`. It sits
**above** the ExUnit progression ladder: LiveViewTest/PhoenixTest still carry
exhaustive pathway coverage; Cucumberex documents and verifies the
**business-level behavior** of major features in language a non-developer can
read.

### When to write a feature file

Write a `.feature` file for every **major user-facing feature** — a flow a user
would name when describing what the app does: sign-up, checkout, publishing a
post, inviting a teammate. Each feature file covers:

- The happy path
- The significant failure paths (validation rejection, denied authorization,
  plan limit reached)
- Tenant isolation, where applicable

Do **not** write feature files for minor UI details (a tooltip, a sort order,
an empty-state message) — those belong in LiveViewTest. If a scenario reads
like a test script ("click the third button") rather than a behavior
("subscriber saves a resource"), it is too low-level for Gherkin.

### Setup

The dep is injected at bootstrap. One-time project setup:

```bash
mix cucumber.init        # scaffolds features/ with step_definitions/ and support/
```

Add the formatter import to `.formatter.exs` so `mix format` doesn't mangle the
DSL:

```elixir
[
  import_deps: [:cucumberex],
  inputs: ["features/**/*.{ex,exs}", ...]
]
```

And make `mix cucumber` run in the test environment (`mix.exs`):

```elixir
def cli do
  [preferred_envs: [cucumber: :test]]
end
```

### Structure

```gherkin
# features/save_resource.feature
Feature: Saving resources
  Subscribers keep a personal list of saved resources.

  Scenario: Subscriber saves a resource
    Given a subscriber signed in
    And a published resource "Intro to OTP"
    When they save "Intro to OTP"
    Then "Intro to OTP" appears in their saved list

  Scenario: Visitor is sent to sign in
    Given a published resource "Intro to OTP"
    When a visitor tries to save "Intro to OTP"
    Then they are asked to sign in
```

Step definitions live in `features/step_definitions/` and drive the app the
same way your ExUnit tests do — context functions for setup, PhoenixTest for
the user-visible flow, `data-test` selectors for assertions. The `world` map
threads scenario state (current session, created records) between steps:

```elixir
# features/step_definitions/save_resource_steps.ex
defmodule SaveResourceSteps do
  use Cucumberex.DSL
  use MyAppWeb, :verified_routes
  import Phoenix.ConnTest, only: [build_conn: 0]
  import PhoenixTest
  import MyApp.Factory

  @endpoint MyAppWeb.Endpoint

  given_ "a subscriber signed in", fn world ->
    user = insert(:user)
    insert(:subscription, user: user, status: :active)
    session = build_conn() |> MyAppWeb.ConnCase.authenticate(user) |> visit(~p"/")
    Map.merge(world, %{user: user, session: session})
  end

  given_ "a published resource {string}", fn world, title ->
    Map.put(world, :resource, insert(:post, title: title, status: :published))
  end

  when_ "they save {string}", fn world, _title ->
    session =
      world.session
      |> visit(~p"/resources/#{world.resource}")
      |> click_button("[data-test=\"save-resource-#{world.resource.id}\"]", "Save")

    %{world | session: session}
  end

  then_ "{string} appears in their saved list", fn world, title ->
    world.session
    |> visit(~p"/saved")
    |> assert_has("[data-test=\"saved-items\"]", text: title)

    world
  end
end
```

### Database sandbox

Scenarios hit the real test database. Check out an Ecto sandbox connection per
scenario in `features/support/env.ex` hooks so scenarios stay isolated:

```elixir
# features/support/env.ex
defmodule CucumberEnv do
  use Cucumberex.Hooks.DSL

  before_ fn world ->
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(MyApp.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(MyApp.Repo, {:shared, self()})
    world
  end

  after_ fn world ->
    Ecto.Adapters.SQL.Sandbox.checkin(MyApp.Repo)
    world
  end
end
```

### Running

```bash
mix cucumber                          # full acceptance suite
mix cucumber features/checkout.feature
mix cucumber --tags "@smoke and not @slow"
mix cucumber --strict                 # fail on undefined/pending steps (use in CI)
mix cucumber --format junit --out cucumber-report.xml   # CI report
```

Like the rest of the suite, feature scenarios do not execute JavaScript —
scenarios that genuinely require JS stay in Wallaby/Playwright; tag any
browser-backed scenarios `@e2e` and exclude them from the default run.

---

## Test Selector Convention: `data-test` Attributes

All interactive and conditionally rendered elements in LiveView templates must
have `data-test` attributes. Tests target these attributes, never CSS classes
or DOM structure.

```heex
<%!-- ✅ CORRECT — test-stable selector --%>
<button phx-click="delete_post" data-test={"delete-post-#{@post.id}"}>
  Delete
</button>

<div :if={@posts == []} data-test="empty-state">
  No posts yet.
</div>

<%!-- ❌ WRONG — fragile, breaks when you change styling --%>
<button phx-click="delete_post" class="btn btn-danger text-sm">
  Delete
</button>
```

Naming convention for `data-test` values:
- Actions: `delete-post-{id}`, `subscribe-btn`, `save-resource-{id}`
- Containers: `post-list`, `resource-list`, `saved-items`
- Items: `post-{id}`, `resource-{id}`, `user-{id}`
- States: `empty-state`, `loading-state`, `error-state`
- Navigation: `nav-admin`, `nav-content`, `nav-analytics`

---

## Testing Streams

LiveView collections render via **streams** (the generator default in Phoenix
1.8; streams have existed since LiveView 0.18.16 and superseded
`temporary_assigns` for collections —
[Fly.io streams blog](https://fly.io/phoenix-files/phoenix-dev-blog-streams/)).
A stream keeps the collection out of socket assigns entirely, so you **never
assert against `socket.assigns` for streamed items** — assert against the
rendered HTML.

Stream functions ([LiveView docs](https://hexdocs.pm/phoenix_live_view/Phoenix.LiveView.html)):

- `stream(socket, :items, items)` — initialize; pass `:limit` to bound the
  number of DOM elements retained (e.g. `stream(socket, :items, items, limit: 50)`).
- `stream_insert(socket, :items, item)` / `stream_insert(socket, :items, item, at: 0)`
  — handles **both insert and update** (re-inserting an item with the same DOM id
  updates it in place). **There is no `stream_update`.**
- `stream_delete(socket, :items, item)` — remove an item.
- `stream_configure(socket, :items, opts)` — configure dom id / options before
  the first `stream/3,4`.

In the template, each item gets a stable `data-test` id:

```heex
<ul phx-update="stream" id="posts">
  <li :for={{dom_id, post} <- @streams.posts} id={dom_id} data-test={"post-#{post.id}"}>
    {post.title}
  </li>
</ul>
```

In tests, drive the mutation (via `render_hook/3`, a `phx-click`, or
`send(view.pid, ...)` for a PubSub-style message), then assert on the rendered
HTML with `has_element?/2` — **`assert_has_element?` does not exist:**

```elixir
test "inserting a post renders it in the stream", %{conn: conn} do
  conn = conn_for(insert(:user))      # scope-aware authenticated conn
  {:ok, view, _html} = live(conn, ~p"/posts")

  post = insert(:post)
  send(view.pid, {:post_created, post})

  # Assert on rendered HTML, NOT view |> assigns
  assert has_element?(view, "[data-test=\"post-#{post.id}\"]")

  # Update: stream_insert with the same id updates in place
  send(view.pid, {:post_updated, %{post | title: "Renamed"}})
  assert has_element?(view, "[data-test=\"post-#{post.id}\"]", "Renamed")

  # Delete
  send(view.pid, {:post_deleted, post})
  refute has_element?(view, "[data-test=\"post-#{post.id}\"]")
end
```

### LazyHTML and colocated hooks

LiveView 1.1 switched the test HTML engine from Floki to **LazyHTML**, which
supports modern CSS selectors like `:is()` and `:has()` in `has_element?/2` and
`element/3` selectors
([LiveView 1.1 release](https://www.phoenixframework.org/blog/phoenix-liveview-1-1-released),
[changelog](https://hexdocs.pm/phoenix_live_view/changelog.html)). Test
**colocated hooks** server-side through `LiveViewTest` — assert that the markup
and `phx-hook` wiring render correctly. Escalate to Wallaby/Playwright only when
you need the hook's JavaScript to actually execute in a browser.

---

## Test Foundations

### DataCase

All context/unit tests use `MyApp.DataCase` which sets up the Ecto sandbox.

```elixir
defmodule MyApp.DataCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      alias MyApp.Repo
      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import MyApp.DataCase
      import MyApp.Factory
    end
  end

  setup tags do
    MyApp.DataCase.setup_sandbox(tags)
    :ok
  end

  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(MyApp.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end

  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
```

### ConnCase

Integration and LiveView tests use `MyAppWeb.ConnCase`.

```elixir
defmodule MyAppWeb.ConnCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint MyAppWeb.Endpoint
      use MyAppWeb, :verified_routes
      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import MyApp.Factory
      import MyAppWeb.ConnCase
    end
  end

  setup tags do
    MyApp.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc "Authenticates the connection as the given user."
  def authenticate(conn, user) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> put_session(:user_id, user.id)
    |> assign(:current_user, user)
  end

  # If your app is multi-tenant, include tenant context:
  @doc "Authenticates the connection as the given user with the given membership."
  def authenticate(conn, user, membership) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> put_session(:user_id, user.id)
    |> put_session(:membership_id, membership.id)
    |> assign(:current_user, user)
    |> assign(:current_membership, membership)
    |> assign(:organization, membership.organization)
  end

  @doc "Builds an authenticated conn for a user."
  def conn_for(user) do
    build_conn() |> authenticate(user)
  end
end
```

### WallabyCase

Browser-based E2E tests use `MyAppWeb.WallabyCase`.

```elixir
defmodule MyAppWeb.WallabyCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      use Wallaby.DSL
      import Wallaby.Query
      import MyApp.Factory

      @endpoint MyAppWeb.Endpoint
    end
  end

  setup tags do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(MyApp.Repo)

    unless tags[:async] do
      Ecto.Adapters.SQL.Sandbox.mode(MyApp.Repo, {:shared, self()})
    end

    metadata = Phoenix.Ecto.SQL.Sandbox.metadata_for(MyApp.Repo, self())
    {:ok, session} = Wallaby.start_session(metadata: metadata)
    {:ok, session: session}
  end
end
```

---

## Factories (ExMachina)

> **Fixtures vs factories.** `phoenix.gen` generators emit dependency-free
> **fixture** modules (e.g. `MyApp.AccountsFixtures.user_fixture/1`,
> `user_scope_fixture/0`) — perfectly fine as a zero-dependency default
> ([Phoenix testing guide](https://phoenix.hexdocs.pm/testing.html)). Adopt
> `ExMachina` once relational boilerplate grows (building org → membership →
> resource graphs). The two coexist: keep generated fixtures, add factories for
> the complex graphs.

Use `ExMachina` for test data. If your app is multi-tenant, every
tenant-scoped factory must include an `organization` association.

```elixir
defmodule MyApp.Factory do
  use ExMachina.Ecto, repo: MyApp.Repo

  # Multi-tenant: include an organization (tenant) factory
  def organization_factory do
    %MyApp.Accounts.Organization{
      name: sequence(:name, &"Test Org #{&1}"),
      slug: sequence(:slug, &"test-org-#{&1}"),
    }
  end

  def user_factory do
    %MyApp.Accounts.User{
      email: sequence(:email, &"user-#{&1}@example.com"),
    }
  end

  # Multi-tenant: membership links a user to an organization with a role
  def membership_factory do
    %MyApp.Accounts.Membership{
      user: build(:user),
      organization: build(:organization),
      role: :editor,
    }
  end

  # Example resource factory — adapt field names to your domain
  def post_factory do
    %MyApp.Content.Post{
      organization: build(:organization),   # omit if not multi-tenant
      title: sequence(:title, &"Post #{&1}"),
      status: :draft,
    }
  end

  # If your app integrates with a media/video provider, include provider IDs:
  def media_asset_factory do
    %MyApp.Content.MediaAsset{
      organization: build(:organization),
      title: sequence(:title, &"Asset #{&1}"),
      provider_asset_id: sequence(:provider_asset_id, &"asset_#{&1}"),
      provider_playback_id: sequence(:provider_playback_id, &"playback_#{&1}"),
      provider_status: "ready",
    }
  end

  # If your app integrates with a payment provider:
  def plan_factory do
    %MyApp.Billing.Plan{
      organization: build(:organization),
      name: "Monthly",
      provider_price_id: sequence(:provider_price_id, &"price_#{&1}"),
      amount: 999,
      interval: :monthly,
    }
  end

  def subscription_factory do
    %MyApp.Billing.Subscription{
      organization: build(:organization),
      user: build(:user),
      plan: build(:plan),
      provider_subscription_id: sequence(:provider_sub_id, &"sub_#{&1}"),
      status: :active,
    }
  end
end
```

---

## Scopes in Tests

Phoenix 1.8 makes **scopes** a first-class, generator-default concept: context
functions take a `scope` as their **first argument** — `get_post!(scope, id)`,
`create_post(scope, attrs)` — and the scope carries the current `user` and (for
multi-tenant apps) the current `organization`
([Scopes guide](https://phoenix.hexdocs.pm/scopes.html),
[Phoenix 1.8 release](https://www.phoenixframework.org/blog/phoenix-1-8-released)).
A scope is a `%MyApp.Accounts.Scope{}`. `phx.gen.auth` emits `Scope.for_user/1`
and a `user_scope_fixture/0` test helper; scopes are removable via `--no-scope`.

> The cross-scope **isolation assertion** below is a recommended best practice,
> not something the generator emits — add it yourself for every scoped context.

In this ExMachina template (no generated fixtures), provide an equivalent
`scope_for/1` helper. Add it to `MyApp.DataCase`/`MyAppWeb.ConnCase` `using`
imports (or `MyApp.Factory`) so every test can build a scope from a user:

```elixir
# Single-tenant: scope carries just the user
def scope_for(%MyApp.Accounts.User{} = user) do
  MyApp.Accounts.Scope.for_user(user)
end

# Equivalent to Phoenix's generated user_scope_fixture/0
def user_scope_fixture do
  scope_for(insert(:user))
end

# Multi-tenant variant: build org + membership, then a scope carrying both
def org_scope_fixture(role \\ :editor) do
  membership = insert(:membership, role: role)

  MyApp.Accounts.Scope.for_user(membership.user)
  |> MyApp.Accounts.Scope.put_organization(membership.organization)
end
```

Every scope-first context call passes the scope first:

```elixir
test "create_post scopes the post to the caller", %{} do
  scope = user_scope_fixture()

  {:ok, post} = MyApp.Content.create_post(scope, %{title: "Hello"})

  # Reading back through the same scope succeeds
  assert MyApp.Content.get_post!(scope, post.id).id == post.id
end
```

### Asserting isolation (multi-tenant or per-user)

A different scope must not be able to read another scope's data. Assert it
raises:

```elixir
test "get_post!/2 isolates other scopes", %{} do
  scope = org_scope_fixture()
  other_scope = org_scope_fixture()

  {:ok, post} = MyApp.Content.create_post(scope, %{title: "Private"})

  assert_raise Ecto.NoResultsError, fn ->
    MyApp.Content.get_post!(other_scope, post.id)
  end
end
```

> The existing `ConnCase` helpers above still `assign(:current_user, ...)` for
> backwards compatibility; in scope-default apps the conn carries
> `current_scope` and your context calls take the scope first. Prefer the
> scope-first pattern in new tests.

---

## Mocks (Mox)

Define behaviours for every external service client so implementations can be
swapped in tests. This pattern applies to any external provider: a media/video
provider, a payment provider, an S3-compatible object store, an email service,
etc.

### Setup

```elixir
# test/support/mocks.ex
Mox.defmock(MyApp.Content.MockMediaClient,
  for: MyApp.Content.MediaClientBehaviour)

Mox.defmock(MyApp.Billing.MockPaymentClient,
  for: MyApp.Billing.PaymentClientBehaviour)
```

```elixir
# config/test.exs
config :my_app, :media_client, MyApp.Content.MockMediaClient
config :my_app, :payment_client, MyApp.Billing.MockPaymentClient
```

### Usage pattern

```elixir
import Mox

setup :verify_on_exit!

test "handles media asset ready webhook" do
  # Scope-first contracts: build a scope, derive the org from it if multi-tenant
  scope = org_scope_fixture()
  asset = insert(:media_asset, organization: scope.organization, provider_status: "preparing")

  expect(MockMediaClient, :get_asset, fn asset_id ->
    assert asset_id == asset.provider_asset_id
    {:ok, %{duration: 120.5, max_resolution: "1080p"}}
  end)

  payload = %{
    "type" => "asset.ready",
    "data" => %{"id" => asset.provider_asset_id}
  }

  assert :ok = perform_job(MyApp.Workers.MediaWebhookProcessor, %{payload: payload})

  updated = Content.get_asset!(scope, asset.id)
  assert updated.provider_status == "ready"
  assert updated.duration == 120.5
end
```

See `external-service-integration.md` for media provider conventions and
`payment-integration.md` for payment provider conventions.

---

## Oban Testing

Use `Oban.Testing` to assert jobs are enqueued and to execute them in tests
([Oban testing docs](https://oban.hexdocs.pm/testing.html)).

### Testing modes

Set the test queue's testing mode in `config/test.exs`:

| Mode      | Behavior                                                        | Use for                                |
|-----------|-----------------------------------------------------------------|----------------------------------------|
| `:manual` | Jobs are inserted but **not** executed; assert with `assert_enqueued` | Asserting enqueue without side effects |
| `:inline` | Jobs execute **synchronously** in the enqueuing process, bypassing the queue | Asserting the full job effect end-to-end |

```elixir
# config/test.exs — default to :manual so jobs don't fire unexpectedly
config :my_app, Oban, testing: :manual
```

Override per-test (or per-block) with `Oban.Testing.with_testing_mode/2`:

```elixir
Oban.Testing.with_testing_mode(:inline, fn ->
  {:ok, _} = MyApp.Content.publish_post(scope, post)  # triggers job inline
end)
```

### Asserting enqueue

`assert_enqueued/1` accepts filters — `worker`, `args`, `queue`, `scheduled_at`:

```elixir
use Oban.Testing, repo: MyApp.Repo

test "webhook controller enqueues processing job" do
  conn = build_conn()
  |> put_req_header("content-type", "application/json")
  |> post("/webhooks/provider", Jason.encode!(%{type: "asset.ready", ...}))

  assert response(conn, 200)

  # Every Oban job carries its scope id in args — assert on it
  assert_enqueued(worker: MyApp.Workers.WebhookProcessor,
                  args: %{organization_id: scope.organization.id})
end
```

### Executing a worker directly

`perform_job(worker, args_map, opts \\ [])` builds a job from the args map,
validates it, runs `perform/1`, and returns the worker's result. Test the happy
path, idempotency, and error returns:

```elixir
test "processor is idempotent" do
  scope = org_scope_fixture()
  asset = insert(:media_asset, organization: scope.organization, provider_status: "preparing")
  args = %{organization_id: scope.organization.id, asset_id: asset.id}

  assert :ok = perform_job(MyApp.Workers.MediaWebhookProcessor, args)
  # Running again produces the same result, no duplicate side effects
  assert :ok = perform_job(MyApp.Workers.MediaWebhookProcessor, args)
end

test "processor returns an error for a missing record" do
  assert {:error, :not_found} =
           perform_job(MyApp.Workers.MediaWebhookProcessor,
                       %{organization_id: 0, asset_id: 0})
end
```

---

## Required Test Categories

For every new feature, ALL of the following test types are required before the
feature is considered complete:

### 1. Schema/changeset tests
- Valid attrs → valid changeset
- Missing required fields → errors
- Invalid values → errors
- Unique constraint violations → errors

### 2. Context function tests
- Happy path
- Error paths (every `{:error, _}` return)
- **Tenant isolation** — org A cannot access org B's data (if multi-tenant)
- Edge cases (empty input, nil, boundary values)

### 3. RBAC tests (for admin/internal features)
- Authorized role → action succeeds
- Unauthorized role → action denied
- Cross-org user → action denied (if multi-tenant)

### 4. LiveView pathway tests (for EVERY user-facing feature)
- **Every possible user pathway through the feature** (see "The E2E Rule")
- Page renders with expected elements
- Every `handle_event` produces the correct outcome
- Every conditional render is tested in both states
- Form validation errors render correctly
- Flash messages appear for success and error
- Plan/subscription gating redirects unauthenticated or unpaid users
- Multi-tenant isolation — other org's data never appears (if multi-tenant)

### 5. Wallaby E2E tests (ONLY for JS-dependent features)
- Tagged with `@moduletag :e2e`
- Only for: TypeScript hooks, drag-and-drop, payment provider redirects, visual rendering
- NOT for anything LiveViewTest can cover

### 6. Oban worker tests
- Happy path processing
- Idempotency (running twice produces same result)
- Error handling (malformed payload, missing records)

### 7. Cucumberex feature file (for MAJOR user-facing features)
- Gherkin `.feature` file covering the happy path and significant failure paths
- Authorization/plan-gating scenarios where applicable
- Tenant isolation scenario (if multi-tenant)
- See "Acceptance Tests: Cucumberex" above for when a feature qualifies as major

---

## Running Tests

```bash
# Run all tests except E2E (default for development)
mix test

# Run with coverage
mix test --cover

# Run a specific file
mix test test/my_app/content/content_test.exs

# Run a specific test by line number
mix test test/my_app/content/content_test.exs:42

# Run only E2E tests (requires Chrome + ChromeDriver)
mix test --only e2e

# Run everything including E2E
mix test --include e2e

# Run the Cucumberex acceptance suite
mix cucumber
```

### CI requirements

All of the following must pass before deploy:
- `mix test --exclude e2e` — all unit and integration tests green
- `mix test --only e2e` — all Wallaby E2E tests green (separate CI job)
- `mix cucumber --strict` — all acceptance scenarios green, none undefined/pending
- `mix compile --warnings-as-errors` — no compiler warnings
- `mix format --check-formatted` — code is formatted
- `mix credo --strict` — no credo violations
- `mix dialyzer` — no dialyzer warnings
- `npx tsc --noEmit` — TypeScript type checks pass (if using TypeScript hooks)
