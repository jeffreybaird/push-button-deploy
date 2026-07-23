# Testing

Load this file when writing tests, setting up test infrastructure, or reviewing
test coverage. Generic Ruby template for **modular Sinatra + Sequel + SQLite**.

> **Baseline:** Ruby 3.3+ · RSpec · Rack::Test (request specs drive `App`) ·
> Capybara with the rack-test driver (feature/E2E) · FactoryBot · WebMock/VCR
> (HTTP) · data-testid selectors.

Maturity tags: **[stable]** = mature, safe to rely on · **[active]** =
maintained, evolving · **[optional]** = adopt only if the need exists.

Loose gem pins below use `~>` — pin to the minor you adopt, let patch float.
Replace `MyApp` / `my_app` with your real app/module names. The Sinatra base
class is always `App` (a fixed name), booted by `run App` in `config.ru`.

---

## 1. Tests Are a Contract, Not an Obstacle

Existing tests describe **intended behavior**. They are specifications, not
suggestions. These rules are absolute:

1. **Never modify an existing test to make it pass.** A previously-passing test
   that fails after your change means your change broke intended behavior. Fix
   the code, not the test. Only exception: a deliberate, explicitly-stated
   behavior change.
2. **Never weaken an assertion** to pass a failing test.
3. **Never delete a test to resolve a failure** — flag it for discussion.
4. **Never change existing function behavior to satisfy a new test** — add a new
   method/parameter instead.
5. **A new feature that breaks existing tests** carries the burden of proof —
   integrate without breaking existing behavior.
6. **If you believe a test is genuinely wrong**, flag it with a comment and ask
   before changing.
7. **Given a bug report**, write a failing test for the expected behavior first,
   then fix the code.
8. **Find the root cause** — don't take the shortest route around an error
   message.

The suite is a ratchet: it only moves forward.

---

## 2. Test Layout

```
spec/
├── models/          # Sequel::Model validations, datasets, associations
├── services/        # service objects: happy + error + authz + isolation
├── requests/        # full-stack route behavior, App via Rack::Test; fast
├── features/        # Capybara feature specs (rack-test driver); no JS by default
├── policies/        # policy-object specs (app/policies/*_policy.rb)
├── clients/         # Faraday client specs (WebMock/VCR)
├── factories/       # FactoryBot definitions
├── support/         # shared contexts, helpers, WebMock/VCR config
│   ├── factory_bot.rb
│   ├── capybara.rb
│   ├── rack_test.rb
│   ├── vcr.rb
│   └── webmock.rb
├── fixtures/
│   └── vcr_cassettes/
│       └── webhooks/
│           ├── payment_succeeded.yml
│           └── asset_ready.yml
└── spec_helper.rb
```

There is no `rails_helper` — the whole harness lives in **`spec_helper.rb`**. It
boots the modular app, migrates a **fresh** SQLite test database with
`Sequel::Migrator` before the suite, and wraps every example in a transaction
that is rolled back afterward (Sequel's equivalent of Rails'
transactional-fixtures). See `.claude/database.md` for Sequel/SQLite/Litestream
specifics.

```ruby
# spec/spec_helper.rb
ENV["APP_ENV"] = "test"

require "sequel"
require_relative "../config/database"   # defines the global DB (test SQLite file)
require_relative "../app"               # class App < Sinatra::Base

require "rspec"
require "rack/test"
require "capybara/rspec"
require "factory_bot"

# Build the test schema from scratch before anything runs.
Sequel.extension :migration
DB.drop_table?(:schema_info)            # start clean; the test DB is disposable
Sequel::Migrator.run(DB, File.expand_path("../db/migrate", __dir__))

Dir[File.expand_path("support/**/*.rb", __dir__)].sort.each { |f| require f }

RSpec.configure do |config|
  config.include FactoryBot::Syntax::Methods

  # Derive :type from the directory (no rspec-rails to infer it for us).
  config.define_derived_metadata(file_path: %r{/spec/requests/}) { |m| m[:type] = :request }
  config.define_derived_metadata(file_path: %r{/spec/features/}) { |m| m[:type] = :feature }

  # Every example runs inside a transaction rolled back at the end.
  # auto_savepoint: true turns transactions inside the code-under-test into
  # savepoints, so their COMMIT/ROLLBACK nests instead of ending the outer one.
  config.around(:each) do |example|
    DB.transaction(rollback: :always, auto_savepoint: true) { example.run }
  end
end
```

```ruby
# spec/support/rack_test.rb — drive the modular Sinatra app in request specs
require "rack/test"

module RequestHelpers
  include Rack::Test::Methods

  # Rack::Test needs an `app`; point it at the modular Sinatra base class.
  def app
    App
  end

  # Log in through the real route so the app's before filter sets Current.user
  # exactly as in production — do not poke session internals from the spec.
  def sign_in(user, password: "supers3cret!")
    post "/login", email: user.email, password: password
  end
end

RSpec.configure do |config|
  config.include RequestHelpers, type: :request
end
```

The transaction-per-example strategy shares **one** SQLite connection across the
spec and the in-process request, so both see the same uncommitted data. A
real-browser `:js` spec (Section 3) runs the app in a separate thread with its
own connection and cannot see that transaction — clean those with an explicit
row-delete `after` hook instead of relying on rollback.

---

## 3. Default Tool Ladder

Escalate only when the rung below cannot cover the case. Reserve the browser for
genuine JavaScript behavior (there is no Turbo/Stimulus here — just small
vanilla JS in `public/js/`); it is slow and flaky compared to request specs.

| Scenario                                              | Tool                              | Maturity   |
|-------------------------------------------------------|-----------------------------------|------------|
| Model validation / dataset / association              | model spec                        | [stable]   |
| Business logic, authorization, tenant isolation       | service spec (unit)               | [stable]   |
| One route, full stack, no JS                          | request spec (Rack::Test)         | [stable]   |
| Multi-page flow, server-rendered, no JS               | feature spec (Capybara rack-test) | [stable]   |
| JS interaction, real browser                          | feature spec (Capybara `:js`)     | [active]   |
| CSS / visual rendering verification                   | feature spec (Capybara `:js`)     | [active]   |

Ladder: **model + service unit specs → request specs (Rack::Test, full stack,
fast) → feature specs (Capybara rack-test for server-rendered flows; the real
browser only for JavaScript).**

Feature specs default to Capybara's **rack-test** driver (in-process, no JS).
Tag the browser ones `:js` to switch to Selenium/Cuprite, and **exclude `:js`
from the fast dev run**:

```ruby
# .rspec or CI: fast loop skips the browser
# bundle exec rspec --tag ~js
```

```ruby
# spec/support/capybara.rb
require "capybara/rspec"

Capybara.app               = App                        # mount the modular app
Capybara.default_driver    = :rack_test                 # no JS — fast, in-process
Capybara.javascript_driver = :selenium_chrome_headless  # only for :js specs
Capybara.default_selector  = :css

RSpec.configure do |config|
  config.include Capybara::DSL, type: :feature
end
```

Capybara: [github.com/teamcapybara/capybara](https://github.com/teamcapybara/capybara) — `[stable]`.

---

## 4. Factories (FactoryBot)

Use [`factory_bot`](https://github.com/thoughtbot/factory_bot) (`~> 6.4`) —
`[stable]`. There is no `factory_bot_rails`, so wire definition loading yourself
(shown below) and `include FactoryBot::Syntax::Methods` (done in `spec_helper`).
Provide factories for the core graph: account/tenant, user,
membership-with-role, the example `note` resource, and resources carrying
external provider ids.

`build` vs `create`: prefer **`build`** (in-memory, no DB) for unit specs that
don't need persistence; use **`create`** only when the record must exist in the
DB (request/feature specs, association lookups). `build_stubbed` is the fastest
when you need a record with an id but no DB write.

```ruby
# spec/support/factory_bot.rb
require "factory_bot"
FactoryBot.definition_file_paths = [File.expand_path("../factories", __dir__)]
FactoryBot.find_definitions
```

```ruby
# spec/factories/accounts.rb
FactoryBot.define do
  factory :account do                      # the tenant
    sequence(:name) { |n| "Test Org #{n}" }
    sequence(:slug) { |n| "test-org-#{n}" }
  end

  factory :user do
    sequence(:email) { |n| "user-#{n}@example.com" }
    password { "supers3cret!" }            # the model's password= hashes via bcrypt
  end

  factory :membership do
    user
    account
    role { :editor }

    trait(:admin)  { role { :admin } }
    trait(:viewer) { role { :viewer } }
  end

  # The example domain resource.
  factory :note do
    account
    association :author, factory: :user
    sequence(:title) { |n| "Note #{n}" }
    body { "…" }
  end

  # Resource carrying external provider ids (media/payment/etc.)
  factory :media_asset do
    account
    sequence(:title) { |n| "Asset #{n}" }
    sequence(:provider_asset_id)    { |n| "asset_#{n}" }
    sequence(:provider_playback_id) { |n| "playback_#{n}" }
    provider_status { "ready" }

    trait(:preparing) { provider_status { "preparing" } }
  end

  factory :subscription do
    account
    user
    sequence(:provider_subscription_id) { |n| "sub_#{n}" }
    status { :active }
  end
end
```

Use **traits** for variation (roles, statuses) rather than separate factories.
FactoryBot instantiates `Sequel::Model` subclasses like any other object:
`build` calls `.new`, `create` calls `.save`.

---

## 5. External Services — Never Hit Real APIs

Third-party HTTP goes through **Faraday** client classes in `app/clients/`
(e.g. `MyApp::MediaClient`) — see `.claude/external-service-integration.md`.
Block all real outbound HTTP in the suite. Two complementary tools:

- **WebMock** ([github.com/bblimke/webmock](https://github.com/bblimke/webmock),
  `~> 3.23`) — `[stable]`. Disables real connections; stub specific
  request/response pairs explicitly.
- **VCR** ([github.com/vcr/vcr](https://github.com/vcr/vcr), `~> 6.3`) —
  `[stable]`. Records a real interaction once into a "cassette" (YAML) and
  replays it thereafter. Best for integration specs against a real provider's
  shape.

```ruby
# spec/support/webmock.rb — block ALL real HTTP up front
require "webmock/rspec"
WebMock.disable_net_connect!(allow_localhost: true)
```

```ruby
# spec/support/vcr.rb
require "vcr"
VCR.configure do |c|
  c.cassette_library_dir = "spec/fixtures/vcr_cassettes"
  c.hook_into :webmock
  c.filter_sensitive_data("<API_KEY>") { ENV["MYAPP_API_KEY"] }  # never record secrets
  c.configure_rspec_metadata!
end
```

Two valid strategies — pick per spec:

| Strategy                    | When                                                      |
|-----------------------------|-----------------------------------------------------------|
| Stub the **client class**   | Unit specs of code that calls your `MyApp::MediaClient`; fast, no HTTP layer involved |
| Stub the **HTTP layer**     | Verifying the client itself builds the right Faraday request / parses the response (WebMock or VCR) |

```ruby
# Stub the client class (unit-level):
media = instance_double(MyApp::MediaClient,
                        get_asset: { duration: 120.5, max_resolution: "1080p" })
allow(MyApp::MediaClient).to receive(:new).and_return(media)

# Or replay a recorded interaction (integration-level):
it "fetches the asset", :vcr do   # uses cassette named after the example
  expect(MyApp::MediaClient.new.get_asset("asset_123")).to include(status: "ready")
end
```

Rule: **no external API call ever fires for real in the suite**, and **no secret
is recorded into a cassette** (filter it).

---

## 6. Test Selectors — `data-testid` Mandatory

All interactive and conditionally-rendered elements get a `data-testid`
attribute. Tests target **these attributes, never CSS classes or DOM structure**
(classes change with styling; testids are a stable contract).

```erb
<%# ✅ CORRECT — test-stable selector %>
<button data-testid="delete-note-<%= note.id %>">Delete</button>
<div data-testid="empty-state" <%= "hidden" if notes.any? %>>No notes yet.</div>

<%# ❌ WRONG — fragile, breaks on restyle %>
<button class="btn btn-danger text-sm">Delete</button>
```

In Capybara, target the attribute directly:

```ruby
find('[data-testid="delete-note-1"]').click
expect(page).to have_css('[data-testid="empty-state"]')
```

A full feature spec (rack-test driver, no JS) drives the server-rendered flow
through those selectors:

```ruby
# spec/features/managing_notes_spec.rb
require "spec_helper"

RSpec.feature "Managing notes", type: :feature do
  let(:account) { create(:account) }
  let(:user)    { create(:user) }
  before { create(:membership, user:, account:, role: :editor) }

  scenario "an editor creates a note" do
    # log in through the real form — no JS, rack-test in-process
    visit "/login"
    fill_in "email",    with: user.email
    fill_in "password", with: "supers3cret!"
    click_button "Sign in"

    visit "/notes"
    expect(page).to have_css('[data-testid="empty-state"]')

    click_link "New note"
    fill_in "note[title]", with: "Write the spec"
    click_button "Save"

    expect(page).to have_css('[data-testid="note-list"]')
    expect(page).to have_css('[data-testid^="note-"]', text: "Write the spec")
  end
end
```

Naming convention for `data-testid` values:
- Actions: `delete-note-{id}`, `subscribe-btn`, `save-resource-{id}`
- Containers: `note-list`, `resource-list`, `saved-items`
- Items: `note-{id}`, `resource-{id}`, `user-{id}`
- States: `empty-state`, `loading-state`, `error-state`
- Navigation: `nav-admin`, `nav-content`, `nav-analytics`

---

## 7. Background-Job Testing

By default the template ships **no background-job system** — domain work runs
inline inside the service object during the request. Because SQLite allows **one
writer at a time**, keep those transactions short and never fan out parallel
writes (see `.claude/database.md`). There is no ActiveJob.

If you genuinely need durable async work, adopt **Sidekiq** (Redis); for light,
non-durable async a thread pool or `sucker_punch` is the small-scale option. Do
not pretend Solid Queue exists. When you do run jobs, assert three things:
**(a) it gets enqueued** with the right args (including account/tenant id),
**(b) idempotency** — running twice produces the same result with no duplicate
side effects, **(c) error handling** — a malformed payload or missing record
returns/raises as designed.

### Sidekiq — `[stable]`

Framework-agnostic. Use
[`Sidekiq::Testing`](https://github.com/sidekiq/sidekiq/wiki/Testing).

| Mode                      | Behavior                                              | Use for                          |
|---------------------------|-------------------------------------------------------|----------------------------------|
| `Sidekiq::Testing.fake!`  | Jobs pushed onto a `jobs` array, **not executed**     | Asserting enqueue without effects |
| `Sidekiq::Testing.inline!`| Jobs execute **synchronously** when enqueued          | Asserting full job effect end-to-end |

```ruby
require "sidekiq/testing"

it "enqueues the processor with the account id" do
  Sidekiq::Testing.fake! do
    Notes::Publish.call(account:, note:)
    expect(WebhookProcessorWorker.jobs.size).to eq(1)
    expect(WebhookProcessorWorker.jobs.last["args"]).to eq([account.id, note.id])
  end
end

it "is idempotent" do
  args = [account.id, asset.id]
  expect { WebhookProcessorWorker.new.perform(*args) }.not_to raise_error
  expect { WebhookProcessorWorker.new.perform(*args) }  # second run, same result
    .not_to change { MediaAsset.with_pk!(asset.id).provider_status }
end

it "raises on a missing record" do
  expect { WebhookProcessorWorker.new.perform(0, 0) }
    .to raise_error(Sequel::NoMatchingRow)
end
```

---

## 8. Required Coverage

For every new feature, ALL applicable categories below are required before it is
considered complete.

### Models / data objects
- Valid attrs → valid
- Missing required fields → invalid with the expected error (`validation_helpers`
  `validates_presence`, message `"is not present"`)
- Invalid values → invalid
- Unique constraint surfaced — `validates_unique` on save, or a DB-level unique
  index raising `Sequel::UniqueConstraintViolation`
- Each **dataset method / scope** returns the right set (and a soft-delete model
  excludes `deleted_at`-set rows by default; `with_deleted` includes them)

### Services / business logic
- Happy path — returns `Success(...)`
- **Every error path** — each `Failure([:tag, ...])` return / raised error
- **Authorization** — authorized actor succeeds, unauthorized denied (policy
  objects; see `.claude/rbac.md`)
- **Tenant / per-user isolation** — an actor in account A cannot read or mutate
  account B's data (see below). This is the highest-value category.
- Edge cases (empty, nil, boundary values)

A service spec exercising the first three:

```ruby
# spec/services/notes/create_spec.rb
require "spec_helper"

RSpec.describe Notes::Create do
  let(:account) { create(:account) }
  let(:author)  { create(:user) }
  before { create(:membership, user: author, account:, role: :editor) }

  describe ".call" do
    it "creates a note scoped to the account (happy path)" do
      result = described_class.call(account:, author:, params: { title: "Draft", body: "…" })

      expect(result).to be_success
      note = result.value!
      expect(note.account_id).to eq(account.id)
      expect(Note.where(account_id: account.id).count).to eq(1)
    end

    it "returns a tagged Failure on a blank title (nothing persisted)" do
      result = described_class.call(account:, author:, params: { title: "" })

      expect(result).to be_failure
      expect(result.failure).to eq([:invalid, { title: ["is not present"] }])
      expect(Note.count).to eq(0)
    end

    it "denies a viewer (authorization)" do
      viewer = create(:user)
      create(:membership, user: viewer, account:, role: :viewer)

      result = described_class.call(account:, author: viewer, params: { title: "x" })

      expect(result).to be_failure
      expect(result.failure.first).to eq(:forbidden)
    end
  end
end
```

### Request specs (every route)
- Each route's success response (status + body/redirect)
- **Authorization** — wrong role / unauthenticated → denied or redirected
- Flash messages for success and failure
- Validation errors rendered
- Cross-tenant request → blocked (if multi-tenant)

```ruby
# spec/requests/notes_spec.rb
require "spec_helper"

RSpec.describe "Notes", type: :request do   # drives App via Rack::Test (def app; App; end)
  let(:account) { create(:account) }
  let(:user)    { create(:user) }
  before do
    create(:membership, user:, account:, role: :editor)
    sign_in(user)
  end

  describe "POST /notes" do
    it "creates a note and redirects to the list" do
      post "/notes", note: { title: "Ship it", body: "today" }

      expect(last_response.status).to eq(302)
      follow_redirect!
      expect(last_response.body).to include("Ship it")
    end

    it "re-renders with an error state on invalid input" do
      post "/notes", note: { title: "" }

      expect(last_response.status).to eq(422)
      expect(last_response.body).to include('data-testid="error-state"')
    end

    it "blocks an unauthenticated request" do
      clear_cookies   # drop the signed-in session
      post "/notes", note: { title: "x" }

      expect(last_response.status).to eq(401).or eq(302)
    end
  end
end
```

### Feature specs (JS-only flows)
- Tagged `:js`, excluded from the fast run
- Only for behavior the request/rack-test layer cannot exercise: `public/js/`
  vanilla-JS interactions, drag-and-drop, payment-provider redirect/return,
  CSS/visual rendering
- **Not** for anything a request spec or a rack-test feature spec already covers

### Job specs (only if Sidekiq is adopted)
- Happy-path processing
- Idempotency (run twice → same result)
- Error handling (malformed payload, missing record)

### Tenant / per-user isolation

Express isolation through `Current.account` and account-scoped Sequel datasets
(see `.claude/multi-tenancy.md`). The assertion that matters: a query scoped to
one account must never return another account's row.

```ruby
it "isolates notes across accounts" do
  account       = create(:account)
  other_account = create(:account)
  note = create(:note, account:)

  # The account-scoped finder must not surface another account's record.
  # Notes.find_for does: account.notes_dataset.with_pk!(id)
  expect {
    Notes.find_for(other_account, note.id)
  }.to raise_error(Sequel::NoMatchingRow)
end
```

---

## 9. CI Gates

All must pass before merge/deploy. Run the fast suite locally before every
commit.

```bash
bundle exec rspec --tag ~js               # fast: unit + request + rack-test feature specs
bundle exec rspec --tag js                # browser specs (separate CI job; needs Chrome)
bundle exec rubocop                       # style + lint (add rubocop-sequel, rubocop-rspec)
bundle exec bundler-audit check --update  # dependency CVE scan
bundle exec erb_lint --lint-all           # ERB lint (optional)
```

| Gate           | Gem / tool                                                              | Scope     | Maturity   |
|----------------|-------------------------------------------------------------------------|-----------|------------|
| Tests          | [rspec](https://rspec.info/) `~> 3.13`                                   | Sinatra   | [stable]   |
| Rack integration | [rack-test](https://github.com/rack/rack-test) `~> 2.1`               | Sinatra   | [stable]   |
| Feature / E2E  | [capybara](https://github.com/teamcapybara/capybara) `~> 3.40`          | Sinatra   | [stable]   |
| Factories      | [factory_bot](https://github.com/thoughtbot/factory_bot) `~> 6.4`       | Sinatra   | [stable]   |
| HTTP stub      | [webmock](https://github.com/bblimke/webmock) `~> 3.23` / [vcr](https://github.com/vcr/vcr) `~> 6.3` | Sinatra | [stable] |
| Lint/style     | [rubocop](https://github.com/rubocop/rubocop) `~> 1.65`                 | Sinatra   | [stable]   |
| CVE audit      | [bundler-audit](https://github.com/rubysec/bundler-audit) `~> 0.9`      | Sinatra   | [stable]   |
| ERB lint       | [erb_lint](https://github.com/Shopify/erb_lint) `~> 0.5`                | template  | [optional] |

Notes:
- **Brakeman is Rails-aware** — it follows Rails routing/views and cannot map a
  modular Sinatra/Rack app, so its value here is limited. Rely on `rubocop`
  (with `rubocop-sequel` + `rubocop-rspec`), `bundler-audit`, and review;
  reach for Semgrep as an optional static analyzer if you need one.
- The test DB is disposable: `spec_helper` migrates it fresh each run, so no
  seeding gate is required.
- Run the suite, lint, and CVE gates green before any deploy. In production the
  schema is applied by a one-off `rake db:migrate` gate before traffic switches
  (see `.claude/deployment.md` and `.claude/database.md`). `main` is always
  releasable.
