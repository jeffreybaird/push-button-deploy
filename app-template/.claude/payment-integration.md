# Payment / Billing Integration

> **Optional module.** Include only if your app charges money.

Load this file when working on subscriptions, plans, checkout, or payment webhook processing.

This document specializes the base external-service-integration pattern for payment/billing providers. See `external-service-integration.md` for the generic single-client + behaviour + Mox foundation this builds on.

The running example uses **Stripe** as the payment provider. The patterns apply equally to Paddle, Braintree, or any provider with a webhook-driven subscription model.

---

## Client Architecture

### Single entry point: `MyApp.Billing.Client`

All payment API calls go through this module. No other module in the codebase may call the payment library directly.

For Stripe, [`stripity_stripe`](https://stripity-stripe.hexdocs.pm) (`~> 3.x`) is the
community-default Elixir library ([source](https://github.com/code-corps/stripity_stripe)).
It owns the HTTP layer internally, so you wrap it behind `MyApp.Billing.Client` rather
than layering Req on top — the behaviour + Mox foundation is what makes it swappable and
testable. For other providers (Paddle, Braintree), wrap their SDK the same way, or build a
Req-based client per `external-service-integration.md` if no maintained SDK exists.

```elixir
defmodule MyApp.Billing.Client do
  @behaviour MyApp.Billing.ClientBehaviour

  @impl true
  def create_customer(params), do: ...

  @impl true
  def create_subscription(customer_id, price_id), do: ...

  @impl true
  def cancel_subscription(subscription_id), do: ...

  @impl true
  def create_checkout_session(params), do: ...

  @impl true
  def create_billing_portal_session(customer_id, return_url), do: ...
end
```

### Behaviour for testability

```elixir
defmodule MyApp.Billing.ClientBehaviour do
  @callback create_customer(map()) :: {:ok, map()} | {:error, term()}
  @callback create_subscription(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  @callback cancel_subscription(String.t()) :: {:ok, map()} | {:error, term()}
  @callback create_checkout_session(map()) :: {:ok, map()} | {:error, term()}
  @callback create_billing_portal_session(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  @callback verify_webhook(raw_body :: String.t(), signature :: String.t()) ::
              {:ok, Stripe.Event.t()} | {:error, :invalid_signature}
end
```

### Config-injected client

```elixir
defp billing_client do
  Application.get_env(:my_app, :billing_client, MyApp.Billing.Client)
end
```

In `config/test.exs`:

```elixir
config :my_app, :billing_client, MyApp.Billing.MockClient
```

---

## Data Model

### Key schemas

| Schema         | Purpose                                                       |
|----------------|---------------------------------------------------------------|
| `Plan`         | A subscription tier (name, provider price ID, amount, interval) |
| `Subscription` | A customer's active subscription to a plan                    |

### Provider identifiers stored locally

| Field                     | On Schema      | Purpose                                    |
|---------------------------|----------------|--------------------------------------------|
| `billing_customer_id`     | `User`         | Customer record in the billing provider    |
| `billing_price_id`        | `Plan`         | Provider price/product ID                  |
| `billing_subscription_id` | `Subscription` | Provider subscription object ID            |

> **Marketplace note.** If your app is a marketplace where tenants each have their own billing accounts (e.g. Stripe Connect), add a `billing_account_id` to your tenant schema and thread it through `Client` calls as an optional parameter. Do not bake a single-account assumption into the billing context.

---

## Subscription Flow

### Checkout

1. User clicks "Subscribe"
2. Backend calls `MyApp.Billing.Client.create_checkout_session/1`
3. User is redirected to the provider's hosted checkout page
4. On success, provider redirects back to your app
5. Provider sends a `checkout.completed` webhook
6. The `PaymentWebhookProcessor` Oban worker creates the local `Subscription` record

### Cancellation

1. User clicks "Manage Subscription" → redirected to billing portal
2. Or: user cancels through your app's account page
3. Backend calls `MyApp.Billing.Client.cancel_subscription/1`
4. Provider sends a `subscription.updated` webhook with cancellation details
5. Worker updates local subscription status

### Subscription gating

A `RequireSubscription` plug checks whether the current user has an active subscription. If not, redirect to the pricing/signup page.

```elixir
# Applied only to routes that require an active subscription
pipe_through [:browser, :require_auth, :require_subscription]
```

---

## Webhook Processing

### Inbound endpoint

```elixir
scope "/webhooks" do
  pipe_through :webhook
  post "/billing", MyAppWeb.WebhookController, :billing
end
```

### Signature verification

Every inbound webhook must be verified using the provider's signature mechanism before processing. Reject unverified payloads with a `400` response. Never skip this step.

With Stripe, verify inside `MyApp.Billing.Client.verify_webhook/2` using
[`Stripe.Webhook.construct_event/5`](https://stripity-stripe.hexdocs.pm), which both checks
the `Stripe-Signature` HMAC against the **raw request body** and returns the parsed event:

```elixir
# MyApp.Billing.Client
@impl true
def verify_webhook(raw_body, signature) do
  secret = Application.fetch_env!(:my_app, :billing)[:webhook_secret]

  case Stripe.Webhook.construct_event(raw_body, signature, secret) do
    {:ok, %Stripe.Event{} = event} -> {:ok, event}
    {:error, _reason} -> {:error, :invalid_signature}
  end
end
```

The raw body must be the exact bytes Stripe signed — see the `cache_body_reader` plug in
`external-service-integration.md`.

### Async processing via Oban

Verify the signature synchronously, enqueue an Oban job, respond `200` immediately. Never do business logic in the controller.

```elixir
def billing(conn, _params) do
  payload = conn.assigns[:raw_body]
  signature = get_req_header(conn, "x-provider-signature") |> List.first()

  with {:ok, event} <- MyApp.Billing.Client.verify_webhook(payload, signature),
       {:ok, _job} <- PaymentWebhookProcessor.enqueue(event) do
    send_resp(conn, 200, "ok")
  else
    {:error, :invalid_signature} -> send_resp(conn, 400, "bad signature")
  end
end
```

### Key webhook events to handle

| Event                       | Action                                    |
|-----------------------------|-------------------------------------------|
| `checkout.completed`        | Create local subscription record          |
| `subscription.updated`      | Sync status (active, past_due, canceled)  |
| `subscription.deleted`      | Mark subscription as canceled             |
| `invoice.payment_succeeded` | Update billing status, extend access      |
| `invoice.payment_failed`    | Mark subscription as past_due, notify user|

### Idempotency

Use the provider's event ID as an Oban unique key. Processing the same event twice must produce the same result.

```elixir
defmodule MyApp.Workers.PaymentWebhookProcessor do
  use Oban.Worker, queue: :billing, unique: [keys: [:event_id]]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"event_id" => _event_id, "event_type" => type} = args}) do
    handle_event(type, args)
  end
end
```

> **Edge case:** scope the unique key by tenant (`keys: [:event_id, :organization_id]`) **only** when provider event IDs are not globally unique **and** each tenant uses a separate provider account. Stripe event IDs (this doc's target) are globally unique, so `keys: [:event_id]` is sufficient and correct ([Oban unique jobs](https://hexdocs.pm/oban/Oban.Worker.html#module-unique-jobs)).

---

## Environment Variables

| Variable                  | Required | Purpose                          |
|---------------------------|----------|----------------------------------|
| `BILLING_SECRET_KEY`      | Yes      | Payment provider API secret key  |
| `BILLING_WEBHOOK_SECRET`  | Yes      | Webhook signature verification   |

Set via your deployment secrets manager (e.g. Fly secrets, AWS Secrets Manager). Never in source code or committed config files. Read at runtime only in `config/runtime.exs`.

```elixir
# config/runtime.exs
config :my_app, :billing,
  secret_key: System.fetch_env!("BILLING_SECRET_KEY"),
  webhook_secret: System.fetch_env!("BILLING_WEBHOOK_SECRET")
```

---

## Testing

Use `Mox` to mock `MyApp.Billing.ClientBehaviour`. Never make real payment API calls in tests.

```elixir
import Mox

setup :verify_on_exit!

test "creates a checkout session for the user" do
  user = insert(:user)
  plan = insert(:plan)

  expect(MockBillingClient, :create_checkout_session, fn params ->
    assert params.price_id == plan.billing_price_id
    {:ok, %{id: "session_test_123", url: "https://checkout.example.com/test"}}
  end)

  assert {:ok, session} = MyApp.Billing.create_checkout(user, plan)
  assert session.url =~ "checkout.example.com"
end
```

For webhook processing tests, build the provider event payload manually and pass it directly to the Oban worker's `perform/1` function — no HTTP involved.

```elixir
test "creates subscription on checkout.completed event" do
  user = insert(:user, billing_customer_id: "cus_123")
  plan = insert(:plan, billing_price_id: "price_abc")

  args = %{
    "event_id" => "evt_001",
    "event_type" => "checkout.completed",
    "customer_id" => "cus_123",
    "price_id" => "price_abc"
  }

  assert :ok = perform_job(MyApp.Workers.PaymentWebhookProcessor, args)
  assert MyApp.Billing.active_subscription?(user, plan)
end
```
