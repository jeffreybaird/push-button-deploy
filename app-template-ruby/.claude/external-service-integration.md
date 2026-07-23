# External Service Integration

Pattern for wrapping any third-party API — payment processors, media providers,
email/SMS services, object storage, etc. — into a testable, swappable client
class. The pattern is provider-agnostic; the running examples use a generic media
provider.

> **Optional module.** Include this pattern when your app integrates an external
> API. Skip if no external service integration is needed.

> **Baseline:** Wrap every third-party API behind one Faraday client class in
> `app/clients/` · retry/timeout middleware (`faraday-retry`) · one OpenTelemetry
> span per call · return dry-monads `Success`/`Failure`, never raw HTTP responses ·
> verify webhook signatures over the raw request body before processing · idempotency
> keys on external mutations · secrets via `ENV.fetch`.

This is the foundation that `payment-integration.md` and
`object-storage-integration.md` specialize.

---

## Client Architecture

### One client class per service: a flat class in `app/clients/`

All calls to a given external service go through **one** class. No route, model,
service object, or worker may call the vendor SDK / raw HTTP directly. The Sinatra
scaffold has no autoload-by-nesting — clients are flat classes in `app/clients/`,
each `require`d explicitly.

```ruby
# app/clients/media_client.rb
require "faraday"
require "faraday/retry"        # gem "faraday-retry", "~> 2"
require "dry/monads"
require "securerandom"
require "opentelemetry"

class MediaClient
  include Dry::Monads[:result]

  def create_asset(params, idempotency_key: SecureRandom.uuid)
    post("/assets", params, idempotency_key:)
  end

  def create_upload_url(params, idempotency_key: SecureRandom.uuid)
    post("/upload_urls", params, idempotency_key:)
  end

  def get_asset(asset_id)    = get("/assets/#{asset_id}")

  def delete_asset(asset_id, idempotency_key: SecureRandom.uuid)
    delete("/assets/#{asset_id}", idempotency_key:)
  end

  # ... Faraday connection + handle_response below ...
end
```

Apply the same shape to every service type — one flat client per vendor:

| Service type   | Example class       |
|----------------|---------------------|
| Payment        | `StripeClient`      |
| Email          | `EmailClient`       |
| SMS            | `SmsClient`         |
| Object storage | `StorageClient`     |
| Media / video  | `MediaClient`       |

### Inject the client so tests can stub it

Don't hard-reference `MediaClient` from a service object. Inject it (or resolve it
from a config point) so a spec can pass a double. Ruby has no compile-time
interface, so the *contract* is the set of public methods plus specs — keep the
public method list small and stable.

```ruby
# ✅ injectable — spec passes a double
# app/services/media/create_asset.rb
module Media
  class CreateAsset
    include Dry::Monads[:result]

    def self.call(...) = new(...).call

    def initialize(actor:, attrs:, client: MediaClient.new)
      @actor, @attrs, @client = actor, attrs, client
    end

    def call
      @client.create_asset(@attrs)   # returns a tagged Result
    end
  end
end
```

```ruby
# ❌ untestable without hitting the network — no seam to stub
def call
  MediaClient.new.create_asset(@attrs)
end
```

For a process-wide swap (e.g. a fake in `test`), resolve the class from one config
point instead of a literal. There is no Rails initializer / `MyApp.config` here —
use a plain constant fixed once at boot:

```ruby
# config/boot.rb — evaluated once at startup
MEDIA_CLIENT = ENV["RACK_ENV"] == "test" ? FakeMediaClient : MediaClient
# then default the service to `client: MEDIA_CLIENT.new`
```

### Always return dry-monads Results, never raw HTTP responses

The client maps transport outcomes to the same tagged Results the rest of the app
uses (see `separation-of-concerns.md` / `architecture-decisions.md`). Callers
branch on `:not_found`, never on an HTTP status integer.

```ruby
Success(body)
Failure([:not_found])
Failure([:external_service_error, { status: 500, body: body }])
```

---

## HTTP Client: Default to Faraday

For providers **without** a maintained Ruby SDK, build the client on
[Faraday](https://github.com/lostisland/faraday) (`~> 2`)
<span title="stable">`[stable]`</span> — the community-default HTTP client. Its
middleware stack lets auth, retries, JSON encoding, and instrumentation be
composable layers rather than scattered code.

> **SDK-wrapped providers own their own HTTP.** When a provider ships a
> maintained Ruby gem (e.g. `stripe`, `aws-sdk-s3`), that gem owns the HTTP layer
> internally. You still wrap it in one flat client class (`StripeClient`,
> `StorageClient`) — you just don't add Faraday on top. Faraday is for providers
> you call over raw HTTP.

### Connection with retry, timeout, JSON, and an OTel span per call

```ruby
class MediaClient
  include Dry::Monads[:result]

  TRACER    = OpenTelemetry.tracer_provider.tracer("my_app")
  RETRYABLE = [Faraday::TimeoutError, Faraday::ConnectionFailed].freeze

  def initialize(conn: nil)
    @conn = conn || build_connection
  end

  private

  def build_connection
    Faraday.new(url: base_url) do |f|
      f.request :json                        # encode request bodies as JSON
      # Retry ONLY safe/idempotent verbs by default; honor Retry-After.
      f.request :retry,
        max: 3,
        interval: 0.5,
        backoff_factor: 2,                   # exponential backoff
        retry_statuses: [429, 502, 503, 504],
        methods: %i[get head options],       # NOT post/put/delete unless idempotency-keyed
        exceptions: RETRYABLE,
        retry_block: ->(env:, **) { honor_retry_after(env) }
      f.response :json                       # parse JSON response bodies
      f.options.timeout      = 10            # total read timeout (s)
      f.options.open_timeout = 5             # connection open timeout (s)
      f.headers["Authorization"] = "Bearer #{api_key}"
      # No :instrumentation middleware — that hook is ActiveSupport::Notifications.
      # opentelemetry-instrumentation-faraday (from opentelemetry-instrumentation-all)
      # patches the adapter and emits a transport span per request automatically.
    end
  end

  # One explicit domain span per call carries the semantic attributes
  # (peer service, operation, idempotency key) the auto transport span can't.
  def post(path, body, idempotency_key:)
    TRACER.in_span("media.client.post #{path}", kind: :client) do |span|
      span.set_attribute("peer.service", "media")
      span.set_attribute("idempotency.key", idempotency_key)
      handle_response(@conn.post(path, body, { "Idempotency-Key" => idempotency_key }))
    end
  rescue Faraday::Error => e
    Failure([:external_service_error, e.message])
  end

  def get(path)
    TRACER.in_span("media.client.get #{path}", kind: :client) do
      handle_response(@conn.get(path))
    end
  rescue Faraday::Error => e
    Failure([:external_service_error, e.message])
  end

  def handle_response(res)
    case res.status
    when 200..299 then Success(res.body)
    when 404      then Failure([:not_found])
    else Failure([:external_service_error, { status: res.status, body: res.body }])
    end
  end

  def base_url = ENV.fetch("MEDIA_API_URL")
  def api_key  = ENV.fetch("MEDIA_API_KEY")
end
```

[`faraday-retry`](https://github.com/lostisland/faraday-retry) is a separate gem
in Faraday 2 — it is not bundled. It honors the `Retry-After` header and applies
exponential backoff with jitter.

A shared `Instrument`/tracing wrapper can centralize the `TRACER.in_span` boilerplate
across clients — see `observability.md`.

### Alternatives

| Library | When |
|---|---|
| **Faraday** `~> 2` <span title="stable">`[stable]`</span> | Default. Middleware composition, swappable adapter, broad ecosystem. |
| `Net::HTTP` (stdlib) | Zero dependencies, one-off internal call. No retry/backoff out of the box. |
| `HTTParty` | Simple scripts; thinner middleware story than Faraday. |
| `Typhoeus` | Parallel/concurrent request fan-out (libcurl). Niche. |

Pick one per client. Don't mix HTTP libraries inside a single client class.

---

## Retries and Circuit Breakers

Three layers, each for a different failure mode. Combine them; don't conflate.

| Concern | Where it lives |
|---|---|
| Transient blip (one bad request) | Faraday `:retry` middleware (safe verbs only, exp backoff, honors `Retry-After`) |
| Non-idempotent mutation retry | Only with an `Idempotency-Key` so the provider dedupes server-side |
| Sustained outage / fail fast | Circuit breaker — add [`stoplight`](https://github.com/bolshakov/stoplight) `~> 4` <span title="stable">`[stable]`</span> or [`circuitbox`](https://github.com/yammer/circuitbox) <span title="stable">`[stable]`</span> |
| Durable retry of critical work | A background worker's own retries — **Sidekiq** `sidekiq_options retry:` (the scaffold has no job runner by default; see Webhooks) |

### Idempotent retries only

GET/HEAD can be replayed safely. **POST/PUT/DELETE cannot** — replaying a
non-idempotent mutation can double-charge or double-create. Retry mutations only
when they carry an `Idempotency-Key` header so the provider deduplicates
server-side ([Stripe's convention](https://stripe.com/docs/api/idempotent_requests)).
The connection above scopes Faraday retries to `%i[get head options]` for exactly
this reason.

The mutation helpers set the `Idempotency-Key` header **once** on the request, so
Faraday replays the *same* key across its internal retries — the provider dedupes.
For retry-safety across separate call sites (a worker re-running, a user
double-submitting), pass a **stable** key derived from the logical operation rather
than letting each call generate a fresh `SecureRandom.uuid`:

```ruby
MediaClient.new.create_asset(attrs, idempotency_key: "asset-create-#{local_record.id}")
```

### Circuit breaker sits upstream of retries

Retries handle a blip; a **circuit breaker** handles a sustained outage by
failing fast instead of hammering a dead dependency.

```ruby
def create_asset(params, idempotency_key: SecureRandom.uuid)
  Stoplight("media-create-asset")
    .with_fallback { |_error| Failure([:external_service_error, :circuit_open]) }
    .run { post("/assets", params, idempotency_key:) }
end
```

For critical paths, layer all three: Faraday retries collapse a flaky network,
the circuit breaker stops cascading failures, and a durable worker retry survives
a process or node crash.

---

## Webhooks

Inbound webhooks are the inverse direction: the provider calls **you**. The rule
set is fixed and identical across providers:

1. Read the **raw request body** before any param parsing touches it.
2. Verify the HMAC signature over those exact bytes.
3. Reject with `400` if invalid — never process an unverified payload.
4. Do the minimum idempotent write and respond `200` fast. Push heavy work to a
   worker if you have one.
5. Make processing **idempotent** via a stored event id (including account id).

### Verify over the RAW body, before parsing

JSON round-tripping reorders keys and re-serializes — the HMAC will no longer
match. You must verify over the exact bytes the provider signed. In Sinatra that
is `request.body.read` (rewind first, in case something upstream already read it).
There is no Rails CSRF token to skip; a JSON `Content-Type` means Rack won't parse
the body into form params, so it is still intact when you read it.

```ruby
# app/routes/webhooks.rb — registered on App, or inline in app.rb
post "/webhooks/media" do
  request.body.rewind
  payload   = request.body.read                       # raw bytes — read before parsing
  signature = request.env["HTTP_X_PROVIDER_SIGNATURE"]

  halt 400 unless MediaClient.valid_signature?(payload, signature)

  event = JSON.parse(payload)
  Webhooks::Process.call(
    provider_event_id: event["id"],
    account_id:        event.dig("data", "account_id"),
    event_type:        event["type"],
    payload:           event
  )
  status 200                                           # respond fast
end
```

> If `enable :sessions` also turned on `Rack::Protection`, exempt the webhook path
> (e.g. mount webhooks on a separate `Sinatra::Base` without sessions, or
> `set :protection, except: %i[http_origin]`) — signature verification, not Origin
> checking, is what secures this endpoint.

HMAC verification helper (constant-time compare, plain Ruby — no ActiveSupport
`present?`):

```ruby
def self.valid_signature?(payload, signature)
  return false if signature.to_s.empty?
  expected = OpenSSL::HMAC.hexdigest("SHA256", ENV.fetch("MEDIA_WEBHOOK_SECRET"), payload)
  Rack::Utils.secure_compare(expected, signature)
end
```

### Processing: inline, or a Sidekiq worker if durable

The scaffold ships **no background job runner**. Be honest about the trade-off:

| Approach | Enqueue | When |
|---|---|---|
| **Inline** (default) | call `Webhooks::Process.call(...)` in the route | Light work. SQLite is single-writer — keep the transaction short. |
| **Sidekiq** (durable) | `MediaWebhookWorker.perform_async(...)` | Heavy work, or you need retry across a crash. Adds Redis. |

Do not reach for a "unique job key" — no job runner here guarantees job-level
uniqueness. The dedup guarantee is a **data-layer** unique index (below), which
holds regardless of runner.

```ruby
# app/workers/media_webhook_worker.rb — only if you add Sidekiq
class MediaWebhookWorker
  include Sidekiq::Job
  sidekiq_options queue: "webhooks", retry: 5

  def perform(provider_event_id, account_id, event_type, payload)
    Webhooks::Process.call(
      provider_event_id:, account_id:, event_type:, payload:
    )
  end
end
```

### Idempotency — DB guard, not job uniqueness

Providers redeliver the same webhook (retries, at-least-once delivery). Processing
must be idempotent. The portable, correct mechanism is a **unique index on the
provider event id, scoped by account** — a Sequel migration, not a gem. See
`database.md` for migration/SQLite specifics.

```ruby
# db/migrate/010_create_webhook_events.rb
Sequel.migration do
  change do
    create_table(:webhook_events) do
      primary_key :id
      String   :provider_event_id, null: false
      Integer  :account_id,        null: false
      String   :event_type,        null: false
      DateTime :created_at,        null: false
      index %i[provider_event_id account_id], unique: true  # the lock
    end
  end
end
```

```ruby
# app/services/webhooks/process.rb
module Webhooks
  class Process
    include Dry::Monads[:result]

    def self.call(...) = new(...).call

    def initialize(provider_event_id:, account_id:, event_type:, payload:)
      @provider_event_id = provider_event_id
      @account_id        = account_id
      @event_type        = event_type
      @payload           = payload
    end

    def call
      DB[:webhook_events].insert(
        provider_event_id: @provider_event_id,
        account_id:        @account_id,
        event_type:        @event_type,
        created_at:        Time.now
      )                                                   # unique index = the lock
      handle(@event_type, @payload)
      Success(:processed)
    rescue Sequel::UniqueConstraintViolation
      Success(:already_processed)                         # redelivery — safe no-op
    end

    private

    def handle(event_type, payload)
      # create/update local records, emit events, dispatch side effects
    end
  end
end
```

The unique index does the deduplication regardless of how many times processing
runs or how it was triggered — the DB guard is the guarantee. `Sequel` raises
`Sequel::UniqueConstraintViolation` on the duplicate insert; catch it and no-op.

### Generic webhook events

Adapt to your provider's actual event names:

| Event category    | Typical action                                   |
|-------------------|--------------------------------------------------|
| `resource.created`| Create or link the local record                 |
| `resource.ready`  | Mark record active, store final metadata         |
| `resource.failed` | Mark record errored, log provider error details  |
| `resource.deleted`| Soft-delete or clean up the local record         |

---

## Secrets

Provider credentials come from the environment, never from source. There are no
Rails encrypted credentials here — `ENV.fetch` only.

| Mechanism | When |
|---|---|
| **`ENV.fetch`** (`ENV.fetch("MEDIA_API_KEY")`) | Always. Fails loud if the key is missing. |
| **`dotenv`** loads `.env` | Dev/test convenience only — `.env` is gitignored, never committed. |
| **Deployment secret store** | Production. The `push-button-deploy` pipeline injects env vars into the container; nothing lands in the image. |

```ruby
# ❌ secret in source
API_KEY = "sk_live_abc123"

# ✅ from the environment, fail loud if missing
def api_key = ENV.fetch("MEDIA_API_KEY")
```

| Variable | Required | Purpose |
|---|---|---|
| `MEDIA_API_URL` | Yes | Provider base URL |
| `MEDIA_API_KEY` | Yes | Provider API authentication |
| `MEDIA_API_SECRET` | If provider needs it | API secret |
| `MEDIA_WEBHOOK_SECRET` | Yes | Webhook signature verification |

---

## Testing

Never hit a real API in a spec. Stub the injected client, and for the HTTP layer
itself use [WebMock](https://github.com/bblimke/webmock) /
[VCR](https://github.com/vcr/vcr). Each example runs inside a Sequel transaction
rolled back afterward (see `testing.md`).

### Stub the client in service/request specs

```ruby
RSpec.describe Media::CreateAsset do
  it "returns the asset the provider created" do
    client = instance_double(MediaClient)
    allow(client).to receive(:create_asset)
      .and_return(Success({ "id" => "asset_123" }))

    result = described_class.call(actor: actor, attrs: { title: "Clip" }, client: client)

    expect(result).to be_success
    expect(client).to have_received(:create_asset).with(hash_including(title: "Clip"))
  end
end
```

### Block real HTTP; assert the request shape

```ruby
# spec/spec_helper.rb
WebMock.disable_net_connect!(allow_localhost: true)

it "sends an idempotency key on creates" do
  stub = stub_request(:post, "https://api.media.example/assets")
           .with(headers: { "Idempotency-Key" => /.+/ })
           .to_return(status: 200, body: { id: "asset_123" }.to_json,
                      headers: { "Content-Type" => "application/json" })

  MediaClient.new.create_asset({ title: "Clip" })
  expect(stub).to have_been_requested
end
```

### Webhook processing — build the payload by hand, call the service directly

No HTTP. Construct the args and invoke the service.

```ruby
it "processes once and treats redelivery as a safe no-op" do
  asset = create(:asset, provider_status: "preparing")
  args  = { provider_event_id: "evt_1", account_id: asset.account_id,
            event_type: "resource.ready",
            payload: { "id" => "evt_1", "data" => { "asset_id" => asset.provider_id } } }

  result = Webhooks::Process.call(**args)
  expect(result).to be_success
  expect(asset.refresh.provider_status).to eq("ready")

  # redelivery — unique index makes it a no-op, not an error
  expect { Webhooks::Process.call(**args) }.not_to raise_error
end
```

### Signature verification — drive the route with Rack::Test

Compute the HMAC over your test payload with the test secret, then assert a
tampered body is rejected with `400`.

```ruby
RSpec.describe "POST /webhooks/media", type: :request do
  include Rack::Test::Methods
  def app = App

  it "rejects a tampered body with 400" do
    payload = { "id" => "evt_1" }.to_json
    sig     = OpenSSL::HMAC.hexdigest("SHA256", ENV.fetch("MEDIA_WEBHOOK_SECRET"), payload)

    header "X-Provider-Signature", sig
    post "/webhooks/media", %({"id":"tampered"})     # bytes differ from the signed payload
    expect(last_response.status).to eq(400)
  end
end
```

---

## Cross-References

| Topic | File |
|---|---|
| Payment provider integration | `payment-integration.md` |
| Object storage integration | `object-storage-integration.md` |
| Result tuples, events, audit | `architecture-decisions.md` |
| Where client calls belong | `separation-of-concerns.md` |
| Sequel migrations, SQLite, Litestream | `database.md` |
| OTel spans, structured logging | `observability.md` |
| Testing patterns | `testing.md` |
