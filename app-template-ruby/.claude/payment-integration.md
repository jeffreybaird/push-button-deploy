# Payment / Billing Integration

> **Optional module.** Include only if your app charges money.

Load this file when working on subscriptions, plans, checkout, or payment webhook
processing.

This specializes the base pattern in `.claude/external-service-integration.md`
(one client class + injectable seam + raw-body webhook verification + idempotent
processing + a data-layer dedup guard). The running example uses **Stripe**; the
patterns apply equally to Paddle, Braintree, or any provider with a webhook-driven
subscription model.

> **Baseline:** Wrap Stripe behind one `StripeClient` in `app/clients/` (the
> `stripe` gem owns its own HTTP — no Faraday on top) · domain logic in `Billing::`
> service objects returning dry-monads Results · verify the `Stripe-Signature` over
> the raw `request.body.read` **before** parsing, reject `400`, dispatch to
> idempotent handlers · store customer/subscription state in Sequel tables
> (`customers`, `subscriptions`) keyed to `accounts` · idempotency key on every
> mutation · secrets via `ENV.fetch` · **never trust a client-supplied amount**.

---

## Client Architecture

### One client class: `StripeClient`

All payment calls go through this class. **No `Stripe::` calls scattered** across
routes, models, services, or workers — they all funnel through here. The Sinatra
scaffold has no autoload-by-nesting; the client is a flat class in `app/clients/`,
`require`d explicitly (see `.claude/external-service-integration.md`).

The official [`stripe`](https://github.com/stripe/stripe-ruby) gem (`~> 13`)
<span title="stable">`[stable]`</span> owns its own HTTP layer — it does **not**
use Faraday — so you wrap it rather than layering Faraday on top. The wrapper is
what makes billing swappable and testable: specs stub `StripeClient`, never
`Stripe::Checkout::Session`. It returns the same tagged `Success`/`Failure` Results
as the rest of the app and carries one OpenTelemetry span per call.

```ruby
# app/clients/stripe_client.rb
require "stripe"
require "dry/monads"
require "securerandom"
require "opentelemetry"

class StripeClient
  include Dry::Monads[:result]

  TRACER = OpenTelemetry.tracer_provider.tracer("my_app")

  def initialize(sdk: Stripe)
    @sdk = sdk
    @sdk.api_key = ENV.fetch("STRIPE_SECRET_KEY")     # fail loud if unset
  end

  def create_customer(email:, account_id:, idempotency_key: SecureRandom.uuid)
    wrap("stripe.create_customer") do
      @sdk::Customer.create(
        { email:, metadata: { account_id: } },        # account_id rides to the webhook
        { idempotency_key: }                           # mutation → idempotent
      )
    end
  end

  def create_checkout_session(customer_id:, price_id:, account_id:,
                              success_url:, cancel_url:, idempotency_key: SecureRandom.uuid)
    wrap("stripe.create_checkout_session") do
      @sdk::Checkout::Session.create(
        {
          mode:       "subscription",
          customer:   customer_id,
          line_items: [{ price: price_id, quantity: 1 }],   # a price_id, NEVER a client amount
          success_url:, cancel_url:,
          metadata:          { account_id: },               # so the (session-less) webhook can resolve the tenant
          subscription_data: { metadata: { account_id: } }
        },
        { idempotency_key: }
      )
    end
  end

  def cancel_subscription(subscription_id)
    wrap("stripe.cancel_subscription") { @sdk::Subscription.cancel(subscription_id) }
  end

  def billing_portal_url(customer_id:, return_url:)
    wrap("stripe.billing_portal") do
      @sdk::BillingPortal::Session.create(customer: customer_id, return_url:).url
    end
  end

  # Verify AND parse in one call, over the RAW body. Returns the parsed
  # Stripe::Event, or nil on a bad signature so the route can reject with 400.
  def self.construct_event(payload, sig_header)
    Stripe::Webhook.construct_event(payload, sig_header, ENV.fetch("STRIPE_WEBHOOK_SECRET"))
  rescue Stripe::SignatureVerificationError, JSON::ParserError
    nil
  end

  private

  def wrap(span_name)
    TRACER.in_span(span_name, kind: :client) { Success(yield) }
  rescue Stripe::InvalidRequestError => e
    Failure([:validation, e.message])
  rescue Stripe::StripeError => e
    Failure([:external_service_error, e.message])
  end
end
```

### Inject it so specs never call Stripe

Don't hard-reference `StripeClient` inside a service. Inject it (default the
argument) so a spec passes a double. Ruby has no compile-time interface — the
*contract* is the small, stable set of public methods plus specs.

```ruby
# ✅ service takes the client; the spec passes a double
# app/services/billing/create_checkout_session.rb
module Billing
  class CreateCheckoutSession
    include Dry::Monads[:result]

    def self.call(...) = new(...).call

    def initialize(account:, plan:, client: StripeClient.new)
      @account, @plan, @client = account, plan, client
    end

    def call
      customer = Customer.first(account_id: @account.id) or
        return Failure([:no_customer])            # created lazily elsewhere (Billing::EnsureCustomer)

      @client.create_checkout_session(
        customer_id: customer.stripe_customer_id,
        price_id:    @plan.stripe_price_id,        # ← price comes from the DB, never from params
        account_id:  @account.id,
        success_url: url("/billing/success"),
        cancel_url:  url("/plans")
      )
    end

    private

    def url(path) = "#{ENV.fetch('APP_URL')}#{path}"
  end
end
```

```ruby
# ❌ untestable without hitting the network — no seam to stub
def call
  StripeClient.new.create_checkout_session(...)
end
```

For a process-wide swap (a fake in `test`), resolve the class from one constant
fixed at boot rather than a literal — there is no Rails initializer here:

```ruby
# config/boot.rb — evaluated once at startup
STRIPE_CLIENT = ENV["RACK_ENV"] == "test" ? FakeStripeClient : StripeClient
# then default the service to `client: STRIPE_CLIENT.new`
```

---

## Data Model

Customer and subscription state lives in **Sequel tables keyed to `accounts`** — not
on `users`. Billing is an account concern (see `.claude/rbac.md`: roles ride the
membership, money rides the account).

| Table | Purpose |
|---|---|
| `plans` | A subscription tier (`name`, `stripe_price_id`, `amount_cents`, `interval`) |
| `customers` | One row per account → its Stripe customer (`account_id`, `stripe_customer_id`) |
| `subscriptions` | An account's subscription (`account_id`, `plan_id`, `stripe_subscription_id`, `status`) |

```ruby
# db/migrate/020_create_billing_tables.rb  (see .claude/database.md for migration rules)
Sequel.migration do
  change do
    create_table(:plans) do
      primary_key :id
      String    :name,            null: false
      String    :stripe_price_id, null: false, unique: true
      Integer   :amount_cents,    null: false          # display only — Stripe is the source of truth
      String    :interval,        null: false, default: "month"
      TrueClass :active,          null: false, default: true
    end

    create_table(:customers) do
      primary_key :id
      foreign_key :account_id, :accounts, null: false
      String   :stripe_customer_id, null: false
      DateTime :created_at
      index :account_id,         unique: true           # one customer per account
      index :stripe_customer_id, unique: true
    end

    create_table(:subscriptions) do
      primary_key :id
      foreign_key :account_id, :accounts, null: false
      foreign_key :plan_id,    :plans
      String   :stripe_subscription_id, null: false
      String   :status,        null: false, default: "incomplete"
      DateTime :current_period_end
      DateTime :created_at
      DateTime :updated_at
      index :account_id
      index :stripe_subscription_id, unique: true       # dedup + fast lookup on webhook
    end
  end
end
```

```ruby
# app/models/subscription.rb
class Subscription < Sequel::Model
  many_to_one :account
  many_to_one :plan

  ACTIVE_STATUSES = %w[active trialing].freeze

  def active? = ACTIVE_STATUSES.include?(status)   # driven by synced status — never re-queries Stripe
end

# app/models/customer.rb
class Customer < Sequel::Model
  many_to_one :account
end

# app/models/account.rb (add)
class Account < Sequel::Model
  one_to_many :subscriptions
  def subscription = subscriptions_dataset.reverse(:created_at).first   # the current one
end
```

### Provider identifiers stored locally

| Field | On | Purpose |
|---|---|---|
| `stripe_customer_id` | `Customer` (→ `Account`) | Customer record in Stripe |
| `stripe_price_id` | `Plan` | Stripe price/product ID |
| `stripe_subscription_id` | `Subscription` | Stripe subscription object ID |

> **Marketplace note.** For Stripe Connect (each tenant has its own connected
> account), add a `stripe_account_id` to `accounts` and thread it through
> `StripeClient` calls. Don't bake a single-account assumption into the billing
> context.

---

## Subscription Flow — Hosted Checkout

Use Stripe **Checkout Sessions** (hosted page). You never touch card data.

```
Account clicks Subscribe
  → POST /checkout looks the Plan up SERVER-SIDE (client sends a plan id, never a price)
  → Billing::CreateCheckoutSession calls StripeClient#create_checkout_session
  → redirect to checkout.url (Stripe-hosted page)
  → account pays on Stripe
  → Stripe redirects back to success_url
  → Stripe POSTs `checkout.session.completed` to /webhooks/stripe
  → Billing::HandleWebhook activates the local Subscription
```

The redirect is **not** where you create the subscription — the webhook is. The
success_url may never be hit (the user closes the tab); the webhook always fires.

> **Never trust a client-supplied amount.** The request carries a plan identifier
> only. The route resolves it to a `Plan` row and passes the plan's
> `stripe_price_id` — the price/amount is looked up server-side, never read from
> params. Accepting an amount, price, or currency from the client is a
> price-tampering hole.

```ruby
# app/routes/checkout.rb (registered on App)
post "/checkout" do
  require_login!
  # Client sends ONLY a plan id. The price is looked up here — never from params.
  plan = Plan.first(id: params[:plan_id], active: true) or halt 404

  case Billing::CreateCheckoutSession.call(account: Current.account, plan:)
  in Success(checkout)
    redirect checkout.url                          # Stripe-hosted (external host — Sinatra's redirect has no same-host guard)
  in Failure([:no_customer])
    session[:alert] = "Set up billing first."
    redirect "/plans"
  in Failure([:external_service_error, _])
    session[:alert] = "Could not start checkout."
    redirect "/plans"
  end
end
```

Unlike Rails' `redirect_to(url, allow_other_host: true)`, Sinatra's `redirect`
just sets the `Location` header with no same-host guard — redirecting to the
Stripe URL needs nothing special.

---

## Webhook Processing

Same five rules as `.claude/external-service-integration.md`: raw body → verify →
reject `400` → do the minimum idempotent write, respond fast → DB-guard
idempotency. Stripe provides one call that verifies **and** parses.

### Verify over the RAW body, before parsing

[`Stripe::Webhook.construct_event(payload, sig_header, secret)`](https://stripe.com/docs/webhooks/signatures)
checks the `Stripe-Signature` HMAC against the exact bytes and returns the parsed
`Stripe::Event`, raising `Stripe::SignatureVerificationError` on mismatch. JSON
round-tripping reorders keys and re-serializes, so you must verify over the raw
bytes the provider signed — read `request.body.read` **before** anything parses it
(rewind first, in case something upstream already read it).

```ruby
# app/routes/webhooks.rb (registered on App)
post "/webhooks/stripe" do
  request.body.rewind
  payload = request.body.read                          # RAW bytes — read BEFORE parsing
  sig     = request.env["HTTP_STRIPE_SIGNATURE"]

  event = StripeClient.construct_event(payload, sig)   # verifies HMAC over payload, THEN parses
  halt 400 if event.nil?                               # invalid signature → reject, never process

  Billing::HandleWebhook.call(
    stripe_event_id: event.id,
    account_id:      event.data.object.metadata["account_id"],
    event_type:      event.type,
    object:          event.data.object.to_hash
  )
  status 200                                            # respond fast
end
```

> If `enable :sessions` also turned on `Rack::Protection`, exempt the webhook path
> (mount webhooks on a separate `Sinatra::Base` without sessions, or
> `set :protection, except: %i[http_origin]`) — signature verification, not Origin
> checking, is what secures this endpoint. A JSON `Content-Type` means Rack won't
> consume the body into form params, so it's still intact when you read it, and
> there's no Rails CSRF token to skip.

### Processing: inline, or a Sidekiq worker if durable

The scaffold ships **no background job runner** (`.claude/external-service-integration.md`).
Be honest about the trade-off:

| Approach | Enqueue | When |
|---|---|---|
| **Inline** (default) | call `Billing::HandleWebhook.call(...)` in the route | Light work. SQLite is single-writer — keep the transaction short (`.claude/database.md`). |
| **Sidekiq** (durable) | `StripeWebhookWorker.perform_async(...)` | Heavy work, or you need retry across a crash. Adds Redis. |

Do **not** reach for a "unique job key" — no runner here guarantees job-level
uniqueness. The dedup guarantee is a **data-layer unique index** (below).

### Key events

| Event | Action |
|---|---|
| `checkout.session.completed` | Create/activate the local `Subscription` (link `stripe_subscription_id`) |
| `customer.subscription.updated` | Sync status (`active`, `past_due`, `canceled`) |
| `customer.subscription.deleted` | Mark the subscription canceled |
| `invoice.payment_succeeded` | Extend access / record the paid period |
| `invoice.payment_failed` | Mark `past_due`, notify the account |

### Idempotency — DB guard keyed on the Stripe event id

Stripe redelivers events (at-least-once), and event ids are **globally unique** —
perfect for a unique index. **Reuse the `webhook_events` table and its unique index
defined in `.claude/external-service-integration.md`** — do not create a
billing-specific dedup table. `Sequel` raises `Sequel::UniqueConstraintViolation`
on the duplicate insert; catch it and no-op.

```ruby
# the lock already exists — from .claude/external-service-integration.md
add_index :webhook_events, %i[provider_event_id account_id], unique: true
```

```ruby
# app/services/billing/handle_webhook.rb
module Billing
  class HandleWebhook
    include Dry::Monads[:result]

    def self.call(...) = new(...).call

    def initialize(stripe_event_id:, account_id:, event_type:, object:)
      @stripe_event_id = stripe_event_id
      @account_id      = account_id
      @event_type      = event_type
      @object          = object
    end

    def call
      DB[:webhook_events].insert(                       # unique index = the dedup lock
        provider_event_id: @stripe_event_id,
        account_id:        @account_id,
        event_type:        @event_type,
        created_at:        Time.now
      )
      dispatch
      Success(:processed)
    rescue Sequel::UniqueConstraintViolation
      Success(:already_processed)                       # redelivery — safe no-op
    end

    private

    def dispatch
      case @event_type
      when "checkout.session.completed"
        Billing::ActivateSubscription.call(
          account_id: @account_id, customer_id: @object["customer"],
          subscription_id: @object["subscription"]
        )
      when "customer.subscription.updated"
        Billing::SyncSubscription.call(subscription_id: @object["id"], status: @object["status"])
      when "customer.subscription.deleted"
        Billing::SyncSubscription.call(subscription_id: @object["id"], status: "canceled")
      # invoice.payment_succeeded / invoice.payment_failed → extend / mark past_due
      end
    end
  end
end
```

The unique index deduplicates regardless of how many times processing runs or how
it was triggered — the DB guard is the guarantee, not the job runner. Keep the
insert-and-dispatch transaction short: SQLite has one writer, and each handler
(`ActivateSubscription`, `SyncSubscription`) does the minimum write.

---

## Subscription Gating

Reads of the local `subscriptions` row decide access — never re-query Stripe per
request. Gate at the request boundary; the rule lives in a helper or policy, not
inline (see `.claude/rbac.md` for the policy shape).

```ruby
# app.rb — a route-side gate, distinct from role authorization (rbac.md §3)
helpers do
  def require_active_subscription!
    return if Current.account.subscription&.active?
    session[:alert] = "An active subscription is required."
    redirect "/plans"
  end
end

# app/routes/reports.rb
before "/reports*" do
  require_login!
  require_active_subscription!
end
```

For a plan-tier decision that also drives view UI, express it as a policy predicate
so routes, services, and ERB share one rule rather than re-deriving it (the
`policy(record).action?` pattern in `.claude/rbac.md`):

```ruby
# app/policies/report_policy.rb
class ReportPolicy
  def initialize(_user, _record = nil) = (@account = Current.account)
  def index? = @account.subscription&.active?
end
```

`Subscription#active?` reads the **synced** status (§Data Model) — the webhook keeps
it current, so gating is a local read.

---

## Secrets

Provider credentials come from the environment, never from source. There are no
Rails encrypted credentials here — `ENV.fetch` only (dev/test via `dotenv`, prod
via the deploy secret store; see `.claude/deployment.md`).

| Variable | Required | Purpose |
|---|---|---|
| `STRIPE_SECRET_KEY` | Yes | Stripe API secret key |
| `STRIPE_WEBHOOK_SECRET` | Yes | Webhook signature verification (`whsec_…`) |
| `STRIPE_PUBLISHABLE_KEY` | If using Stripe.js | Client-side publishable key |
| `APP_URL` | Yes | Base URL for `success_url` / `cancel_url` |

```ruby
# ❌ secret in source
Stripe.api_key = "sk_live_..."

# ✅ from the environment, fail loud if missing
Stripe.api_key = ENV.fetch("STRIPE_SECRET_KEY")
```

---

## Testing

Stub `StripeClient`. **Never call Stripe in a spec.** Each example runs inside a
Sequel transaction rolled back afterward (see `.claude/testing.md`); `Success`/
`Failure` come from `include Dry::Monads[:result]` in the spec.

### Stub the client in service specs

```ruby
RSpec.describe Billing::CreateCheckoutSession do
  include Dry::Monads[:result]

  it "starts a checkout session for the account's plan" do
    account = create(:account)
    create(:customer, account:, stripe_customer_id: "cus_123")
    plan    = create(:plan, stripe_price_id: "price_abc")
    client  = instance_double(StripeClient)
    allow(client).to receive(:create_checkout_session)
      .and_return(Success(double(url: "https://checkout.stripe.com/c/test")))

    result = described_class.call(account:, plan:, client:)

    expect(result.value!.url).to include("checkout.stripe.com")
    expect(client).to have_received(:create_checkout_session)
      .with(hash_including(price_id: "price_abc"))   # server-side price, not client input
  end
end
```

### Webhook handling — build the payload by hand, call the service

No HTTP, no Stripe. Construct the args, invoke `Billing::HandleWebhook`, and assert
redelivery is a no-op — the unique index makes it one, not an error.

```ruby
it "activates a subscription on checkout.session.completed and ignores redelivery" do
  account = create(:account)
  create(:customer, account:, stripe_customer_id: "cus_123")
  create(:plan, stripe_price_id: "price_abc")
  args = { stripe_event_id: "evt_1", account_id: account.id,
           event_type: "checkout.session.completed",
           object: { "customer" => "cus_123", "subscription" => "sub_1" } }

  Billing::HandleWebhook.call(**args)
  expect(account.subscription).to be_active

  # redelivery — Sequel::UniqueConstraintViolation is caught, so it's a safe no-op
  expect { Billing::HandleWebhook.call(**args) }.not_to raise_error
end
```

### Signature verification — drive the route with Rack::Test

Assert a body Stripe didn't sign is rejected with `400`. Don't reach the network.

```ruby
RSpec.describe "POST /webhooks/stripe", type: :request do
  include Rack::Test::Methods
  def app = App

  it "rejects an unsigned / tampered body with 400" do
    header "Stripe-Signature", "t=1,v1=deadbeef"     # not a valid HMAC over the body
    post "/webhooks/stripe", %({"id":"evt_1"})
    expect(last_response.status).to eq(400)
  end
end
```

For the happy path, either build a validly-signed header with
[`Stripe::Webhook::Signature.generate_header`](https://github.com/stripe/stripe-ruby)
over a fixture payload, or stub `StripeClient.construct_event` to return a built
`Stripe::Event`. Either way, no network.

---

## Cross-References

| Topic | File |
|---|---|
| Base client / webhook pattern, `webhook_events` dedup index | `.claude/external-service-integration.md` |
| Sequel tables, migrations, single-writer SQLite, Litestream | `.claude/database.md` |
| Auth boundary, policy objects, account vs. membership | `.claude/rbac.md` |
| Result tags (`:not_found`, `:forbidden`), audit logging | `.claude/architecture-decisions.md` |
| Where client/service calls belong | `.claude/separation-of-concerns.md` |
| OTel spans, structured logging | `.claude/observability.md` |
| RSpec / Rack::Test patterns, rolled-back transactions | `.claude/testing.md` |
