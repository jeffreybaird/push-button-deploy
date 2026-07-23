# Observability

Load this file when writing service objects, external API client classes,
routes, or Rack middleware. Traces and metrics are first-class citizens — every
operation that matters to the business must be observable.

> **Baseline:** Ruby 3.3+ · modular Sinatra (`class App < Sinatra::Base`) on Puma · OpenTelemetry Ruby SDK + `opentelemetry-instrumentation-all` (Rack/Sinatra/Faraday/Sequel) · a tiny `Instrument` event bus · structured JSON logs (`ougai` or a custom formatter). Auto-instrument HTTP / DB / HTTP-clients; reserve manual spans for business logic. **Sequel span coverage is the shakiest link — verify it, or fall back to manual DB spans (see `.claude/database.md`).**

Replace `MyApp` / `my_app` with your real app name. The Sinatra base class is a
fixed `App`; services and models live in bare namespaces (`Notes::Create`,
`Note`). Maturity tags: **stable** (1.0+, safe to depend on) · **pre-1.0** (0.x —
pin the minor line, expect breaking changes).

---

## Principles

1. **Every business mutation gets a manual span.** If a service object creates,
   updates, or deletes something meaningful, wrap it in a span named
   `my_app.<context>.<operation>`. No library knows your business operations.

2. **Every unwrapped external API call gets a manual span.** Calls from your
   Faraday client classes (`app/clients/`) to payment providers, storage
   providers, or any third-party not already covered by an instrumentation gem
   must produce a span with service-specific attributes.

3. **Background work inherits the trace only when the instrumentation is
   present.** The template ships **no** background jobs. If you add **Sidekiq**,
   its contrib instrumentation propagates context from the enqueuing request
   automatically — do not hand-roll inject/extract on that path. A hand-rolled
   thread pool / `sucker_punch` has **no** propagation; you plumb context
   yourself (see Trace Propagation).

4. **Every business-significant event gets a metric.** Note created, subscription
   created, webhook delivered — if you'd put it on a dashboard, `Instrument.emit`
   it.

5. **Every log line carries context.** `request_id`, `trace_id`, `span_id`, and
   the `account`/`user` ids from `Current` belong in structured log fields for
   every request — never interpolated into the message string.

6. **Don't hand-roll spans around already-instrumented operations.** Inbound HTTP
   (Rack/Sinatra), Faraday, Redis, and Sidekiq (if added) are covered by
   auto-instrumentation; **Sequel** is covered *when its instrumentation is
   active* — confirm it, and only fall back to manual DB spans if it isn't.
   Manual spans are for multi-step business logic and external calls no gem
   wraps. **Don't double-wrap.**

7. **No PII in spans or logs.** IDs only — never emails, names, tokens, or card
   data. PII in the telemetry pipeline is a compliance risk.

---

## OpenTelemetry Bootstrap

Auto-instrumentation does most of the work. Initialize it **before** the first
request is served — in modular Sinatra that means requiring the OTel config from
`config.ru` ahead of `run App`.

### Dependencies

Use pessimistic `~>` ranges so patch/minor updates flow in — **never pin exact
minor versions**, especially for the fast-moving OTel packages. Verify latest on
[rubygems.org](https://rubygems.org). Contrib instrumentation gems are
**pre-1.0** (0.x) — pin the minor line.

```ruby
# Gemfile — current ~> ranges (verify latest; do NOT pin exact minors)
gem "opentelemetry-sdk",           "~> 1.8"   # stable
gem "opentelemetry-exporter-otlp", "~> 0.30"  # pre-1.0 — pin the minor line

# Either the umbrella meta-gem (simplest) — activates every installed instrumentation…
gem "opentelemetry-instrumentation-all", "~> 0.76"  # pre-1.0

# …or specific instrumentation gems (smaller footprint, explicit):
# gem "opentelemetry-instrumentation-rack",    "~> 0.26"  # inbound HTTP layer
# gem "opentelemetry-instrumentation-sinatra", "~> 0.25"  # route spans
# gem "opentelemetry-instrumentation-faraday", "~> 0.27"  # outbound HTTP
# gem "opentelemetry-instrumentation-sequel",  "~> 0.3"   # DB — CONFIRM it resolves/activates
# gem "opentelemetry-instrumentation-redis",   "~> 0.26"  # only if you use Redis
# gem "opentelemetry-instrumentation-sidekiq", "~> 0.26"  # only if you add Sidekiq

# Structured JSON logging (choose one):
gem "ougai", "~> 2.0"   # JSON logger; or roll a stdlib Logger + JSON formatter (no gem)
```

> **Sequel caveat:** `use_all` will activate a Sequel instrumentation **if one is
> installed**, but Sequel coverage in the contrib set is the least reliable of
> the layers here. After boot, run one query and confirm a `db.*` span appears.
> If it doesn't, either bridge Sequel's own logging (`DB.loggers`) into spans or
> wrap hot queries in manual spans. See `.claude/database.md` for the Sequel/
> SQLite specifics this assumes.

> Sources: [opentelemetry-ruby](https://github.com/open-telemetry/opentelemetry-ruby),
> [opentelemetry-ruby-contrib (instrumentation)](https://github.com/open-telemetry/opentelemetry-ruby-contrib),
> [OTel Ruby getting started](https://opentelemetry.io/docs/languages/ruby/).

### Configure

There are no Rails initializers here — put the config in `config/otel.rb` and
require it first. `use_all` activates every installed instrumentation gem.

```ruby
# config/otel.rb
require "opentelemetry/sdk"
require "opentelemetry/instrumentation/all"

OpenTelemetry::SDK.configure do |c|
  c.service_name = "my_app"
  c.use_all   # or c.use "OpenTelemetry::Instrumentation::Sinatra", {} per-gem
end
```

```ruby
# config.ru
require "./config/otel"   # FIRST — instrument before the first request is served
require "./app"
run App
```

### Exporter / endpoint

The OTLP exporter honors the standard spec env vars — the collector address is
an **ops concern, not a code change** (`ENV.fetch`, never hardcoded).

```bash
# runtime env — never hardcode the endpoint in source
OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4318
OTEL_TRACES_EXPORTER=otlp
OTEL_SERVICE_NAME=my_app          # overrides service_name above if set
```

> Sources: [OTel Ruby exporters](https://opentelemetry.io/docs/languages/ruby/exporters/),
> [OTel exporter env spec](https://opentelemetry.io/docs/specs/otel/protocol/exporter/).

### Auto- vs manual instrumentation

Adopt the auto-instrumentation gems for the layers they own; reserve manual
spans for what they cannot see.

| Layer | Covered by (auto) | You write |
|---|---|---|
| Inbound HTTP request | `-rack` + `-sinatra` | nothing |
| DB query (Sequel) | `-sequel` *when active* | manual span only if it isn't |
| Outbound HTTP (Faraday) | `-faraday` | nothing |
| Background job (Sidekiq, if added) | `-sidekiq` | nothing |
| Redis (if used) | `-redis` | nothing |
| Multi-step business logic | — | manual span |
| External call no gem wraps | — | manual span |

```ruby
# ✅ Manual span around a business operation no gem can see
tracer.in_span("my_app.billing.cancel_subscription") { ... }

# ❌ Manual span wrapping a plain Sequel query — -sequel already covers it (when active)
tracer.in_span("my_app.notes.get") { Note[id] }
```

> Source: [OTel Ruby instrumentation](https://opentelemetry.io/docs/languages/ruby/instrumentation/).

---

## Manual Spans

Acquire a tracer once per class, then open spans with `in_span`. The block's
`span` is the current span; nested instrumented calls (Sequel, Faraday) attach
automatically. Service objects still return their dry-monads `Success`/`Failure`
Result from inside the block.

```ruby
# app/services/notes/create.rb
module Notes
  class Create
    TRACER = OpenTelemetry.tracer_provider.tracer("my_app.notes")

    def self.call(account:, params:)
      TRACER.in_span("my_app.notes.create") do |span|
        span.set_attribute("my_app.account.id", account.id)
        # ... multi-step work; child spans (Sequel, Faraday) nest under this one
        Success(note)   # or Failure([:invalid, errors])
      end
    end
  end
end
```

Enrich the current span anywhere downstream without passing it around:

```ruby
span = OpenTelemetry::Trace.current_span
span.set_attribute("my_app.invoice.id", invoice.id)
span.add_event("dunning email queued")
```

### Error handling on a span

```ruby
TRACER.in_span("my_app.payments.charge") do |span|
  charge!
rescue Faraday::Error => e
  span.record_exception(e)
  span.status = OpenTelemetry::Trace::Status.error(e.message)
  raise
end
```

> Source: [OTel Ruby instrumentation](https://opentelemetry.io/docs/languages/ruby/instrumentation/).

---

## `Instrument` — the in-process event bus

There is no `ActiveSupport::Notifications` here (it needs the `activesupport`
gem, and you'd be pulling a large dependency for one feature). Use a tiny
hand-rolled `Instrument` module as the in-process event/metrics bus: emit a
named event at the business-significant moment; subscribers turn events into
metrics, audit entries, or log lines — without the emitter knowing.

```ruby
# app/instrument.rb — a ~30-line event bus, zero gems
module Instrument
  @subscribers = Hash.new { |h, k| h[k] = [] }

  class << self
    # Subscribe once at boot
    def subscribe(event, &block) = @subscribers[event.to_s] << block

    # Emit at the business moment (IDs only, no PII); optional block times the work
    def emit(event, **tags)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result  = block_given? ? yield : nil
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      @subscribers[event.to_s].each { |sub| sub.call(event.to_s, tags, elapsed) }
      result
    end
  end
end
```

```ruby
# Emit — at the business moment (no PII in the tags, IDs only)
Instrument.emit("subscription_created", account_id: account.id, plan: plan.code)

# Subscribe — once at boot (config/otel.rb, or any file required from config.ru)
Instrument.subscribe("subscription_created") do |event, tags, _elapsed|
  Metrics.increment(event, tags: tags)
end
```

Event names are plain `<operation>` snake_case strings (`subscription_created`,
`note_created`). If you later need the richer subscriber ecosystem, you *may*
switch to `ActiveSupport::Notifications` — but only if you add the
`activesupport` gem and accept the dependency.

---

## Span Naming Convention

```
my_app.<context>.<operation>
```

Examples:
- `my_app.notes.create`
- `my_app.notes.update`
- `my_app.billing.create_checkout`
- `my_app.billing.cancel_subscription`
- `my_app.accounts.invite_member`
- `my_app.webhooks.dispatch`
- `my_app.imports.process_record`

External services use the service name:
- `my_app.storage_provider.create_upload_url`
- `my_app.payment_provider.create_subscription`

Jobs (only if you add Sidekiq, and only for an enrichment span):
- `my_app.job.webhook_event_processor`
- `my_app.job.analytics_aggregation`

---

## Span Attributes

### Business attributes — namespace under `my_app.*`

```ruby
span.set_attribute("my_app.account.id", account.id)  # tenant/org scope
span.set_attribute("my_app.user.id", user.id)        # user-initiated ops
```

### External API calls

```ruby
span.add_attributes(
  "my_app.service" => "storage_provider",
  "my_app.idempotency_key" => key
)
```

### Jobs (Sidekiq, if added)

```ruby
span.add_attributes(
  "my_app.account.id" => args["account_id"],
  "messaging.system" => "sidekiq",   # semconv, usually auto-set
  "my_app.job.attempt" => attempt
)
```

### Semantic conventions vs custom attributes

HTTP and DB spans use the OpenTelemetry **semantic convention** names
(`http.request.method`, `http.response.status_code`, `url.path`, `db.system`,
`db.statement`, …). The rack/sinatra instrumentation **auto-emits** the HTTP
ones; the sequel instrumentation emits the DB ones **when it's active** — so
backends recognize them out of the box.

For your own business attributes, namespace under `my_app.*`. Do **not** re-emit
a semconv attribute under a custom name, and do not duplicate one the
auto-instrumentation already sets.

```ruby
# ✅ semconv for HTTP/DB (auto), my_app.* for business attrs
span.set_attribute("my_app.account.id", account.id)

# ❌ duplicating a semconv attribute under a custom name
span.set_attribute("my_app.http_status", 200)  # http.response.status_code already set
```

> Sources: [OTel semantic conventions](https://opentelemetry.io/docs/specs/semconv/),
> [HTTP span conventions](https://opentelemetry.io/docs/specs/semconv/http/http-spans/).

### No PII

```ruby
# ✅ ID only
span.set_attribute("my_app.user.id", user.id)

# ❌ PII in the telemetry pipeline
span.set_attribute("my_app.user.email", user.email)
```

---

## Trace Propagation Through Background Work

The template ships **no** background jobs, so by default a request's trace ends
with the request. Two ways trace context crosses into async work when you add
it:

**Sidekiq (recommended for anything durable).** The contrib Sidekiq
instrumentation **propagates context automatically**: the span created when a
job runs links to the request that enqueued it. You write nothing for context
plumbing — just enrich the active span with business attributes inside the job.

```ruby
class WebhookEventJob
  include Sidekiq::Job   # only once you've added Sidekiq + its instrumentation

  def perform(account_id, event_id)
    OpenTelemetry::Trace.current_span.set_attribute("my_app.account.id", account_id)
    Current.account = Account[account_id]   # see Current section below
    # ... process; trace already linked to the enqueuing request
  end
end
```

**Hand-rolled thread pool / `sucker_punch` (no auto propagation).** Inject
context on enqueue, extract on run yourself.

```ruby
# enqueue
carrier = {}
OpenTelemetry.propagation.inject(carrier)
pool.post { run(args.merge(otel_context: carrier)) }

# run
ctx = OpenTelemetry.propagation.extract(args[:otel_context])
OpenTelemetry::Context.with_current(ctx) { perform(args) }
```

> Source: [opentelemetry-ruby-contrib](https://github.com/open-telemetry/opentelemetry-ruby-contrib).

---

## Metrics

Emit a metric on every business-significant event. Route through `Instrument` so
the emit site stays decoupled from the metrics backend (StatsD / Prometheus /
OTel metrics). There is no built-in metrics store — `Metrics` is a thin adapter
you point at your backend.

```ruby
# app/metrics.rb — thin adapter over your metrics backend
module Metrics
  def self.increment(name, tags: {}) = backend.increment(name, tags: tags)
  # backend = Datadog::Statsd.new(...) or an OTel meter — there is no default.
end
```

| Event | `Instrument.emit` name |
|---|---|
| Note viewed | `note_viewed` |
| Note created | `note_created` |
| Upload initiated | `upload_initiated` |
| Subscription created | `subscription_created` |
| Subscription canceled | `subscription_canceled` |
| Webhook delivered | `webhook_delivered` |
| External API call | `external_api_call` |
| Payment failed | `payment_failed` |

Adapt the table to your domain. The pattern — one metric per significant
business event, emitted via `Instrument`, translated by a subscriber — is
universal.

```ruby
# Subscriber at boot translates events → your metrics backend
%w[note_created subscription_created payment_failed].each do |evt|
  Instrument.subscribe(evt) do |event, tags, _elapsed|
    Metrics.increment(event, tags: tags)  # no PII in tags
  end
end
```

When adding a new feature with a business-significant event:
1. `Instrument.emit` the event at the call site.
2. Subscribe it to the metrics backend (or extend an existing subscriber).
3. Add a test that the event fires with the right payload (see Testing).

---

## Structured Logging

Never interpolate context into the message — emit structured fields. Every
request log carries `request_id`, `trace_id`, `span_id`, and the `account`/`user`
ids in scope.

```ruby
# ✅ structured, searchable
log("note created", note_id: r.id, account_id: account.id)

# ❌ interpolated, not searchable
log("Note #{r.id} created for account #{account.id}")
```

Use **`ougai`** (JSON lines out of the box) or a stdlib `Logger` with a JSON
formatter (no gem). `lograge` and `semantic_logger`/`rails_semantic_logger`
exist, but they're Rails-oriented (they unhook ActionController/ActionView log
subscribers you don't have) — skip them here.

```ruby
# app/logging.rb
require "ougai"
LOGGER = Ougai::Logger.new($stdout)
LOGGER.formatter = Ougai::Formatters::Bunyan.new   # JSON lines
```

Set `request_id` in a `before` filter, then merge the shared context into every
line with a `log` helper on `App`:

```ruby
# app.rb
class App < Sinatra::Base
  before do
    Current.reset
    Current.request_id = env["HTTP_X_REQUEST_ID"] || SecureRandom.uuid
    Current.account    = current_account   # from your auth filter
    Current.user       = current_user
    OpenTelemetry::Trace.current_span.add_attributes(
      "my_app.account.id" => Current.account&.id,
      "my_app.user.id"    => Current.user&.id
    )
  end

  after { Current.reset }

  # every log line merges the request-scoped context
  def log(msg, **fields)
    ctx = OpenTelemetry::Trace.current_span.context
    LOGGER.info(msg, {
      request_id: Current.request_id,
      trace_id:   ctx.hex_trace_id,
      span_id:    ctx.hex_span_id,
      account_id: Current.account&.id,
      user_id:    Current.user&.id
    }.merge(fields))
  end
end
```

Prefer a small `Rack::RequestId` middleware (a few lines, or the `rack-request_id`
gem — `use Rack::RequestId` in `config.ru`) if you want the id assigned before
Sinatra runs; otherwise the `SecureRandom.uuid` fallback in the `before` filter
is fine.

> Source: [ougai](https://github.com/piroor/ougai).

### Log levels

- `debug` — query params, idempotency keys, detailed trace info
- `info` — business events (note created, webhook delivered)
- `warn` — recoverable issues (retry triggered, rate limit approaching)
- `error` — failures needing attention (external API error, payment failed)

---

## `Current` → Span / Log Enrichment

Set the account/user/request id **once** per request, then read it anywhere —
span attributes, log fields, metric tags — instead of threading it through every
method signature. `Current` is the DATA boundary, not authorization.

There is no `ActiveSupport::CurrentAttributes` (that's the `activesupport` gem).
Roll a plain thread/fiber-local module:

```ruby
# app/current.rb — thread-local request context, zero gems
module Current
  class << self
    def store       = (Thread.current[:current] ||= {})
    def account     = store[:account]
    def account=(v) = store[:account] = v
    def user        = store[:user]
    def user=(v)    = store[:user] = v
    def request_id  = store[:request_id]
    def request_id=(v) = store[:request_id] = v
    def reset       = Thread.current[:current] = {}
  end
end
```

**Sinatra does NOT reset it for you.** Puma reuses worker threads, so an
uncleared `Current` leaks the previous request's account/user into the next one.
Always `Current.reset` in an `after` filter (and defensively at the top of the
`before` filter, as shown in the logging section above). This is the one place
where dropping Rails magic costs you a real line of code — do not skip it.

---

## Testing Observability Code

RSpec + Rack::Test drive `App`; each example runs in a Sequel transaction rolled
back after. See `.claude/testing.md` for the harness.

### What to test

- **Custom `Instrument` events fire and carry the right payload.** Subscribe only
  for the block, then detach (add a `capture` helper to `Instrument`, or clear
  subscribers in an `after` hook):

  ```ruby
  # Instrument.capture(event) { ... } => [{ event:, tags:, elapsed: }, ...]
  it "emits note_created with the account id and no PII" do
    events = Instrument.capture("note_created") do
      Notes::Create.call(account: account, params: params)
    end
    expect(events.last[:tags][:account_id]).to eq(account.id)
    expect(events.last[:tags]).not_to have_key(:email)   # no PII in the payload
  end
  ```

- That a span wrapper passes the wrapped return value / raised error through
  unchanged (instrumentation must not alter behavior).

### What NOT to test

- **The OpenTelemetry SDK itself** — span creation, export, attribute storage.
  That's the SDK maintainers' job.
- Auto-instrumentation behavior (rack/sinatra/sequel spans).
- Exact log output format — brittle, changes with formatter config.

---

## New Feature Checklist

- [ ] Business mutations wrapped in a `my_app.<context>.<operation>` span
- [ ] Span attributes include `my_app.account.id` for tenant/user-scoped ops
- [ ] External API calls span with `my_app.service` + idempotency key
- [ ] No manual span around an already-auto-instrumented operation (confirm Sequel spans exist before trusting them)
- [ ] Jobs (if Sidekiq is added) enrich the active span; context propagation is automatic
- [ ] Business-significant events `Instrument.emit`ed → metrics subscriber
- [ ] Logs use structured fields (`request_id`, `trace_id`, ids), not interpolation
- [ ] `Current` set once per request AND `Current.reset` in an `after` filter
- [ ] No PII in any span attribute, log field, or metric tag
- [ ] Error paths call `record_exception` + set span status `error`
- [ ] Test: custom `Instrument` events fire with the right payload (not the SDK)
