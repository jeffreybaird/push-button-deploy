# External Service Integration

Pattern for wrapping any third-party API — payment processors, media providers,
email/SMS services, object storage, etc. — into a testable, swappable client
module. The running example uses a media/video provider but the pattern is
provider-agnostic.

> **Optional module.** Include this pattern when your app integrates an external
> API. Skip if no external service integration is needed.

> **Baseline:** Phoenix 1.8 · Req ~> 0.5 (community-default HTTP client, on Finch) · OTP 27. Wrap third-party APIs in Req-based client modules behind a behaviour.

---

## Client Architecture

### Single entry point: `MyApp.<Service>.Client`

All calls to the external service go through one client module. No other module
in the codebase may call the vendor SDK directly.

Example using a media provider:

```elixir
defmodule MyApp.Media.Client do
  @behaviour MyApp.Media.ClientBehaviour

  @impl true
  def create_asset(params) do
    # vendor SDK call
  end

  @impl true
  def create_upload_url(params) do
    # vendor SDK call
  end

  @impl true
  def delete_asset(asset_id) do
    # vendor SDK call
  end

  @impl true
  def get_asset(asset_id) do
    # vendor SDK call
  end
end
```

Apply the same pattern to other service types:

| Service type     | Example module              |
|------------------|-----------------------------|
| Payment          | `MyApp.Billing.PaymentClient` |
| Email            | `MyApp.Notifications.EmailClient` |
| SMS              | `MyApp.Notifications.SMSClient` |
| Object storage   | `MyApp.Storage.ObjectClient` |
| Media/video      | `MyApp.Media.Client`        |

### Behaviour for testability

The behaviour defines the contract. Tests swap in a Mox mock without touching
production code.

```elixir
defmodule MyApp.Media.ClientBehaviour do
  @callback create_asset(map()) :: {:ok, map()} | {:error, term()}
  @callback create_upload_url(map()) :: {:ok, String.t()} | {:error, term()}
  @callback delete_asset(String.t()) :: :ok | {:error, term()}
  @callback get_asset(String.t()) :: {:ok, map()} | {:error, term()}
end
```

### Resolving the client module from config

Always resolve the implementation at runtime so tests can inject the mock:

```elixir
defp media_client do
  Application.get_env(:my_app, :media_client, MyApp.Media.Client)
end
```

In `config/test.exs`:

```elixir
config :my_app, :media_client, MyApp.Media.MockClient
```

---

## HTTP Client: Default to Req (on Finch)

For providers without a maintained Elixir SDK, build the client on top of an HTTP
library. [Req](https://github.com/wojtekmach/req) (`~> 0.5`) is the **community-default**
high-level client and the one most new Phoenix code reaches for — it is also the
[likely future Phoenix default](https://elixirforum.com/t/preferred-http-library-req-or-httpoison/71163),
though not a formal core mandate today. Treat it as the recommended starting point,
not the only valid option.

What Req gives you out of the box ([docs](https://hexdocs.pm/req/Req.html)):

- Automatic response decompression and body decoding (JSON, etc.)
- Automatic redirect following
- A built-in `retry` step (`:safe_transient` by default — see below)
- Composable request/response **steps**, so auth, idempotency, and logging are
  plain functions you prepend to the pipeline

[Finch](https://github.com/sneako/finch) is the connection-pool adapter Req runs on.
Drop to Finch directly only for bare, high-throughput, single-host call sites where
you want to manage pools yourself. HTTPoison and Tesla remain stable and are fine to
keep in maintenance code, but prefer Req for new clients
([comparison](https://andrealeopardi.com/posts/breakdown-of-http-clients-in-elixir/)).

> **SDK-wrapped providers handle their own HTTP.** When a provider ships a maintained
> Elixir SDK (e.g. `stripity_stripe`), that library owns the HTTP layer internally.
> You still wrap it in a `MyApp.<Service>.Client` module behind a behaviour — you just
> don't add Req on top of the SDK. Req is for providers you call over raw HTTP.

### Req-based client module

Context functions take `scope` first; the client takes already-resolved params.

```elixir
defmodule MyApp.Media.Client do
  @behaviour MyApp.Media.ClientBehaviour

  # One configured Req struct per client. Steps and defaults live here.
  defp req do
    Req.new(
      base_url: base_url(),
      receive_timeout: 10_000,
      retry: :safe_transient,
      max_retries: 3
    )
    |> Req.Request.append_request_steps(auth: &put_auth_header/1)
  end

  @impl true
  def create_asset(params) do
    # Mutations carry an idempotency key (see "Idempotency").
    req()
    |> Req.post(url: "/assets", json: params, headers: idempotency_header())
    |> handle_response()
  end

  @impl true
  def get_asset(asset_id) do
    req()
    |> Req.get(url: "/assets/#{asset_id}")
    |> handle_response()
  end

  # Custom step: inject the provider auth header at request time.
  defp put_auth_header(request) do
    Req.Request.put_header(request, "authorization", "Bearer #{api_key()}")
  end

  defp idempotency_header, do: [{"idempotency-key", Ecto.UUID.generate()}]

  # Always return tagged tuples — never a raw Req response.
  defp handle_response({:ok, %Req.Response{status: status, body: body}})
       when status in 200..299,
       do: {:ok, body}

  defp handle_response({:ok, %Req.Response{status: 404}}), do: {:error, :not_found}

  defp handle_response({:ok, %Req.Response{status: status, body: body}}),
    do: {:error, :external_service_error, %{status: status, body: body}}

  defp handle_response({:error, reason}),
    do: {:error, :external_service_error, reason}

  defp base_url, do: Application.fetch_env!(:my_app, :media_provider)[:base_url]
  defp api_key, do: Application.fetch_env!(:my_app, :media_provider)[:api_key]
end
```

---

## Retries and Circuit Breakers

### Per-request retries (Req)

Req's [`retry` step](https://req.hexdocs.pm/Req.Steps.html) retries **safe transient**
failures by default: GET/HEAD requests that fail with HTTP `408`, `429`, or `500`–`504`,
plus transport errors and timeouts. Defaults are `max_retries: 3` with exponential
backoff, and Req honours a `Retry-After` response header when present.

**POST/PUT/DELETE are not auto-retried** — replaying a non-idempotent mutation can
double-charge or double-create. Retry mutations only when they carry an idempotency
key (see below) so the provider deduplicates server-side.

### Circuit breakers sit upstream of retries

Retries handle a blip; a **circuit breaker** handles a sustained outage by failing
fast instead of hammering a dead dependency. Implement it as either a custom Req step
or a dedicated library such as
[`jvoegele/external_service`](https://github.com/jvoegele/external_service), which
wraps calls in a fuse and exposes retry + circuit-breaker policies.

| Concern                          | Where it lives                                   |
|----------------------------------|--------------------------------------------------|
| Transient blip (one bad request) | Req `retry` step (`:safe_transient`, 3 retries)  |
| Non-idempotent mutation retry    | Only with an idempotency key                     |
| Sustained outage / fail-fast     | Circuit breaker (custom step or `external_service`) |
| Durable retry of critical work   | [Oban job retries](https://hexdocs.pm/oban/Oban.Worker.html) |

For critical paths, combine layers: per-request Req retries for transient blips, **and**
Oban `max_attempts` so the enclosing job retries durably if the whole call fails. The
Req retries collapse a flaky network; the Oban retries survive a process or node crash.

---

## Resource Schema Conventions

### Stored provider identifiers

Keep provider-specific IDs in your schema alongside your own primary key. Use
the provider's own terminology for field names to reduce cognitive friction when
reading logs and provider dashboards.

Example for a media asset:

| Field               | Type     | Purpose                                        |
|---------------------|----------|------------------------------------------------|
| `provider_asset_id` | `string` | Provider's asset identifier                    |
| `provider_playback_id` | `string` | Public resource URL or playback token       |
| `provider_upload_id` | `string` | Transient upload identifier (nullable)        |
| `provider_status`   | `string` | Asset lifecycle status from the provider       |
| `duration`          | `float`  | Duration in seconds (set when asset is ready)  |
| `max_resolution`    | `string` | Quality metadata set from provider response    |

Adapt field names for other service types (e.g. `payment_intent_id`,
`delivery_receipt_id`, `object_key`).

### Never reconstruct provider URLs from raw strings

Always use the stored identifier with the provider's SDK or component. Never
build URLs by string concatenation — they may change format.

```elixir
# ✅ CORRECT — use the stored ID with the provider component
<.media_player asset_id={@asset.provider_playback_id} />

# ❌ WRONG — constructing the URL manually
<video src={"https://cdn.example.com/#{@asset.provider_playback_id}/stream.m3u8"} />
```

---

## Asset Upload / Resource Creation Flow

For services that accept user-supplied binary content (files, images, video),
prefer a direct-upload pattern to avoid proxying bytes through your own server:

1. User initiates upload in the UI.
2. Backend calls the client to obtain a signed upload URL.
3. Client (browser or mobile) uploads directly to the provider.
4. Provider sends a webhook when processing is complete.
5. An Oban worker updates the resource record with final status and metadata.

**Resource bytes never pass through your Phoenix server.** Your server only
brokers the upload URL. This eliminates bandwidth cost and latency for binary
transfers.

---

## Webhook Processing

### Inbound endpoint

```elixir
# In router.ex
scope "/webhooks" do
  pipe_through :webhook  # no CSRF, no session, raw body preserved
  post "/<service>", WebhookController, :<service>
end
```

The `:webhook` pipeline must preserve the raw request body for signature
verification. Parsing the body before verification will break HMAC checks.

HMAC verification must run over the **exact bytes** the provider signed, before JSON
parsing mutates or re-serializes them. Use Plug's `:body_reader` option to stash the
raw body as `Plug.Parsers` reads it
([Plug.Conn docs](https://hexdocs.pm/plug/Plug.Conn.html)):

```elixir
# lib/my_app_web/plugs/cache_body_reader.ex
defmodule MyAppWeb.Plugs.CacheBodyReader do
  @doc "Stashes the raw request body on the conn so webhook HMAC can verify exact bytes."
  def read_body(conn, opts) do
    {:ok, body, conn} = Plug.Conn.read_body(conn, opts)
    conn = update_in(conn.assigns[:raw_body], &[body | &1 || []])
    {:ok, body, conn}
  end
end

# In endpoint.ex — point Plug.Parsers at the cache reader.
plug Plug.Parsers,
  parsers: [:urlencoded, :multipart, :json],
  body_reader: {MyAppWeb.Plugs.CacheBodyReader, :read_body, []},
  json_decoder: Jason
```

The verification step then reads `conn.assigns[:raw_body]` (the chunks reversed and
joined) and computes the HMAC over those bytes — not over the parsed `conn.body_params`.

### Signature verification

Verify every inbound webhook using the provider's signing secret before
processing. Reject unverified payloads with a `400` response. Never skip this
step in production.

### Async processing via Oban

The controller verifies the signature and immediately enqueues an Oban job.
It does not process the webhook synchronously. This keeps webhook response times
fast and decouples processing from delivery.

```elixir
def handle(conn, params) do
  with :ok <- verify_signature(conn) do
    %{payload: params}
    |> MyApp.Workers.ServiceWebhookProcessor.new()
    |> Oban.insert()

    send_resp(conn, 200, "ok")
  else
    {:error, :invalid_signature} -> send_resp(conn, 400, "invalid signature")
  end
end
```

### Generic webhook events to handle

Adapt to your provider's actual event names:

| Event category          | Typical action                                    |
|-------------------------|---------------------------------------------------|
| `resource.created`      | Create or link the local record                   |
| `resource.ready`        | Mark record active, store final metadata          |
| `resource.failed`       | Mark record errored, log provider error details   |
| `resource.deleted`      | Soft-delete or clean up the local record          |
| `payment.succeeded`     | Activate subscription or fulfil order             |
| `payment.failed`        | Notify user, revert provisioned access            |
| `delivery.confirmed`    | Mark notification sent, update delivery record    |

### Idempotency

The Oban worker must be idempotent. Providers may deliver the same webhook more
than once. Use the provider's event ID or resource ID + event type as an Oban
unique key.

```elixir
defmodule MyApp.Workers.ServiceWebhookProcessor do
  use Oban.Worker,
    queue: :webhooks,
    unique: [fields: [:args], keys: [:provider_event_id]]

  @impl true
  def perform(%Oban.Job{args: %{"provider_event_id" => _id} = args}) do
    # process event
  end
end
```

Every Oban job must include `organization_id` in args (if multi-tenant).

### Sending an idempotency key (provider-specific)

How the key reaches the provider is provider-specific. Many APIs accept an
`Idempotency-Key` header on mutations so retries don't duplicate side effects. Illustrative
example for a Req-based client (header name varies — check your provider's docs;
[Stripe's convention](https://stripe.com/docs/api/idempotent_requests)):

```elixir
# Illustrative — provider-specific header name.
Req.post(url, headers: [{"idempotency-key", key}], json: body)
```

The pattern stays provider-agnostic: generate a stable key per logical operation and
let the provider deduplicate.

---

## Environment Variables

Store all provider credentials at runtime only. Never commit secrets to source
or load them from `config/config.exs` / `config/prod.exs`.

| Variable                   | Required | Purpose                          |
|----------------------------|----------|----------------------------------|
| `<SERVICE>_API_KEY`        | Yes      | Provider API authentication      |
| `<SERVICE>_API_SECRET`     | Yes      | Provider API secret (if needed)  |
| `<SERVICE>_WEBHOOK_SECRET` | Yes      | Webhook signature verification   |

Load in `config/runtime.exs`:

```elixir
config :my_app, :media_provider,
  api_key: System.fetch_env!("MEDIA_API_KEY"),
  webhook_secret: System.fetch_env!("MEDIA_WEBHOOK_SECRET")
```

Store secrets as GitHub Actions repository secrets. The deploy workflow writes
them into a mode-600 `.env` on the droplet over SSH at deploy time (never in the
image, cloud-init, or droplet metadata); `runtime.exs` reads them. Never in source
code.

---

## Testing External Service Features

Use `Mox` to mock the behaviour. Never make real API calls in tests.

```elixir
# In test_helper.exs
Mox.defmock(MyApp.Media.MockClient, for: MyApp.Media.ClientBehaviour)

# In your test
import Mox

setup :verify_on_exit!

test "create_asset calls the provider and persists the resource" do
  scope = insert(:organization)

  expect(MyApp.Media.MockClient, :create_upload_url, fn _params ->
    {:ok, "https://uploads.provider.example/signed-url"}
  end)

  assert {:ok, url} = Media.create_upload_url(scope, %{title: "My Video"})
  assert url =~ "signed-url"
end
```

For webhook processing tests, build the payload manually and pass it directly
to the Oban worker's `perform/1` function — no HTTP involved.

```elixir
test "webhook processor marks asset as ready" do
  video = insert(:video, provider_status: "preparing")

  job = %Oban.Job{
    args: %{
      "provider_event_id" => "evt_123",
      "event_type" => "resource.ready",
      "resource_id" => video.provider_asset_id
    }
  }

  assert :ok = MyApp.Workers.ServiceWebhookProcessor.perform(job)
  assert Repo.reload(video).provider_status == "ready"
end
```

---

## Cross-References

| Topic                        | File                          |
|------------------------------|-------------------------------|
| Payment provider integration | `payment-integration.md`      |
| Object storage integration   | `object-storage-integration.md` |
| Scalability patterns         | `scalability.md`              |
| Testing patterns             | `testing.md`                  |
| Observability / spans        | `observability.md`            |
| Architecture decisions       | `architecture-decisions.md`   |
