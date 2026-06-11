# Observability

Load this file when writing context functions, Oban workers, external API
client modules, or LiveViews. Traces and metrics are first-class citizens —
every operation that matters to the business must be observable.

> **Baseline:** Phoenix 1.8 (Bandit) · LiveView 1.1 · OTP 27 · OpenTelemetry Elixir SDK. Use the auto-instrumentation libraries; reserve manual spans for business logic + unwrapped external calls.

---

## Principles

1. **Every context mutation gets a manual span.** If a function creates,
   updates, or deletes something, wrap it in `MyApp.Telemetry.with_span/3`.
   This is a manual-span case: there is no library that knows your business
   operations.

2. **Every unwrapped external API call gets a manual span.** Calls to payment
   providers, media providers, or any third-party service not already covered
   by an instrumentation library must produce a span with service-specific
   attributes.

3. **Every Oban worker gets a span with trace context.** Prefer
   `OpentelemetryOban` (see below) to create the span and propagate the parent
   trace; it wires job spans to the enqueuing request automatically.

4. **Every business-significant event gets a metric.** Resource viewed,
   subscription created, webhook delivered — if you'd put it on a dashboard,
   emit a telemetry event.

5. **Every log line carries context.** `trace_id`, `span_id`, and
   `user_id` must be in Logger metadata for every request and job. If
   multi-tenant, include `org_id` as well.

6. **Don't hand-roll spans around already-instrumented operations.** HTTP
   requests (`OpentelemetryPhoenix`), Ecto queries (`OpentelemetryEcto`), and
   Oban jobs (`OpentelemetryOban`) are covered by auto-instrumentation. Manual
   spans are for multi-step business logic and external calls a library does
   not wrap.

---

## OpenTelemetry Bootstrap

Auto-instrumentation does most of the work. Attach it in `Application.start/2`
**before** the Endpoint child starts so the first request is captured.

### Dependencies

Pin exact versions (`==`) for reproducible builds — **never float minor
versions**, especially for the fast-moving OTel packages where a minor bump can
change span shape or break the exporter wire format. `mix.lock` locks the
resolved tree, but exact pins in `mix.exs` make the intended version explicit and
keep transitive resolution from quietly advancing on an unrelated `mix deps.get`.
Upgrade deliberately — bump the pin in a dedicated, reviewed commit and let CI
catch the regression — instead of letting `~>` ranges drift between machines and
deploys.

```elixir
# mix.exs — current ~> ranges (verify latest on hex.pm; do NOT pin exact minors)
{:opentelemetry_api, "~> 1.4"},
{:opentelemetry, "~> 1.5"},
{:opentelemetry_exporter, "~> 1.8"},
{:opentelemetry_phoenix, "~> 2.0"},
{:opentelemetry_ecto, "~> 1.2"},
{:opentelemetry_bandit, "~> 0.3"},   # pre-1.0 — pin the 0.3.x line
{:opentelemetry_oban, "~> 1.1"},
{:opentelemetry_logger_metadata, "~> 0.2"}
```

### Attach instrumentation before the supervisor

```elixir
# lib/my_app/application.ex
@impl true
def start(_type, _args) do
  # Attach telemetry handlers BEFORE the Endpoint child so the first request
  # is instrumented. These read :telemetry events emitted by Bandit/Phoenix/Ecto.
  OpentelemetryBandit.setup()
  OpentelemetryPhoenix.setup(adapter: :bandit)   # adapter REQUIRED in 2.0 (breaking change)
  OpentelemetryEcto.setup([:my_app, :repo])      # telemetry prefix: [otp_app, repo]
  OpentelemetryOban.setup()                      # spans for job insert + execution

  children = [
    MyApp.Repo,
    {Phoenix.PubSub, name: MyApp.PubSub},
    # ... other children ...
    MyAppWeb.Endpoint                            # Endpoint starts AFTER setup/0 calls
  ]

  Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
end
```

The endpoint must emit the telemetry event `OpentelemetryPhoenix` listens for:

```elixir
# lib/my_app_web/endpoint.ex — required for OpentelemetryPhoenix to start its span
plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]
```

> Sources: [OpentelemetryPhoenix docs](https://opentelemetry-phoenix.hexdocs.pm/OpentelemetryPhoenix.html),
> [OpentelemetryPhoenix readme](https://opentelemetry-phoenix.hexdocs.pm/readme.html),
> [opentelemetry readme](https://hexdocs.pm/opentelemetry/readme.html).

### Exporter / SDK config

```elixir
# config/runtime.exs (runtime — never hardcode the endpoint in compile config)
config :opentelemetry,
  span_processor: :batch,
  traces_exporter: :otlp

config :opentelemetry_exporter,
  otlp_protocol: :http_protobuf,
  # default OTLP/HTTP collector endpoint; override per-env with the env var below
  otlp_endpoint: System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:4318")
```

`OTEL_EXPORTER_OTLP_ENDPOINT` is the standard env var the exporter honors, so
the collector address is an ops concern, not a code change.

### Auto- vs manual instrumentation

Adopt the auto-instrumentation libraries for the layers they own; reserve
manual spans for what they cannot see.

| Layer | Covered by | You write |
|---|---|---|
| Inbound HTTP request | `OpentelemetryBandit` + `OpentelemetryPhoenix` | nothing |
| Ecto query (`Repo.*`) | `OpentelemetryEcto` | nothing |
| Oban job insert + execute | `OpentelemetryOban` | nothing |
| LiveView mount / event | `OpentelemetryPhoenix` | optional enrichment |
| Multi-step business logic | — | `with_span/3` |
| External call not wrapped by a lib | — | `with_span/3` |

```elixir
# ✅ Manual span around a business operation a library can't see
MyApp.Telemetry.with_span "my_app.billing.cancel_subscription", attrs, do: ...

# ❌ Manual span wrapping a plain Repo call — OpentelemetryEcto already covers it
MyApp.Telemetry.with_span "my_app.content.get_resource", %{}, do: Repo.get(Resource, id)
```

> Sources: [auto vs manual instrumentation](https://cribl.io/blog/manual-vs-auto-instrumentation-opentelemetry-choose-whats-right/),
> [OpenTelemetry with Elixir](https://last9.io/blog/opentelemetry-with-elixir/),
> [OTel Erlang tracing](https://uptrace.dev/get/opentelemetry-erlang/tracing),
> [OpentelemetryEcto readme](https://opentelemetry-ecto.hexdocs.pm/readme.html).

---

## Scopes and Observability

A `%MyApp.Accounts.Scope{}` carries the `user` and (if multi-tenant) the
`organization`, and is assigned as `current_scope`. Rather than unpacking scope
fields inside every instrumented function, you can **optionally** extract them
once and set them as span attributes in a span-enrichment `on_mount` hook
(LiveViews) or plug (controllers). This is a convenience aligned with the
existing "every log line carries context" principle, not a mandate — per-call
`with_span/3` attributes still work.

```elixir
# A scope -> span-attribute helper, reused by the on_mount hook and the plug.
defmodule MyApp.Telemetry.ScopeAttributes do
  require OpenTelemetry.Tracer, as: Tracer

  @doc "Set span attributes from a Scope (user + optional organization)."
  def put(%MyApp.Accounts.Scope{} = scope) do
    attrs =
      []
      |> maybe_put("my_app.user.id", scope.user && scope.user.id)
      |> maybe_put("my_app.org.id", scope.organization && scope.organization.id)
      |> maybe_put("my_app.org.slug", scope.organization && scope.organization.slug)

    Tracer.set_attributes(attrs)
  end

  defp maybe_put(attrs, _key, nil), do: attrs
  defp maybe_put(attrs, key, value), do: [{key, value} | attrs]
end
```

> Sources: [Phoenix Scopes](https://phoenix.hexdocs.pm/scopes.html),
> [Phoenix 1.8 released](https://www.phoenixframework.org/blog/phoenix-1-8-released).

---

## Span Naming Convention

```
my_app.<context>.<operation>
```

Examples:
- `my_app.content.create_resource`
- `my_app.content.list_resources`
- `my_app.billing.create_checkout`
- `my_app.billing.cancel_subscription`
- `my_app.engagement.add_to_watchlist`
- `my_app.catalog.reorder_rows`
- `my_app.admin.create_organization`
- `my_app.admin.export_data`
- `my_app.webhooks.dispatch`
- `my_app.imports.process_record`

External services use the service name:
- `my_app.video_provider.create_upload_url`
- `my_app.video_provider.get_asset`
- `my_app.payment_provider.create_subscription`
- `my_app.payment_provider.create_checkout_session`

Oban workers:
- `my_app.worker.webhook_event_processor`
- `my_app.worker.payment_webhook_processor`
- `my_app.worker.webhook_delivery`
- `my_app.worker.analytics_aggregation`

---

## Standard Span Attributes

### Always include on tenant-scoped operations (if multi-tenant)

```elixir
%{
  "my_app.org.id" => organization.id,
  "my_app.org.slug" => organization.slug
}
```

### On user-initiated operations

```elixir
%{
  "my_app.user.id" => user.id
}
```

**No PII in span attributes.** Never put email addresses, names, or other
personally identifiable information in span attributes. User ID is sufficient
for trace correlation. PII in the telemetry pipeline creates compliance risk.

### On external API calls

```elixir
%{
  "http.method" => "POST",
  "http.status_code" => 200,
  "my_app.idempotency_key" => key,
  "my_app.service" => "video_provider" | "payment_provider"
}
```

### On Oban workers

```elixir
%{
  "my_app.org.id" => org_id,          # if multi-tenant
  "my_app.worker" => "WebhookProcessor",
  "oban.queue" => "default",
  "oban.attempt" => attempt
}
```

### On errors

Always set the span status and record the error:

```elixir
Tracer.set_status(:error, inspect(reason))
Tracer.set_attribute("error.type", error_atom_to_string(reason))
```

---

## Semantic Conventions

HTTP and DB spans should use the OpenTelemetry **semantic convention** attribute
names (`http.request.method`, `http.response.status_code`, `url.path`,
`db.system`, `db.statement`, …) — these are emitted for you by
`OpentelemetryPhoenix`/`OpentelemetryBandit` and `OpentelemetryEcto`, so backends
and dashboards recognize them out of the box.

For **custom business attributes**, namespace consistently under `myapp.*`
(e.g. `my_app.org.id`, `my_app.service`). Do **not** re-emit a semconv attribute
under a custom name, and do not duplicate an attribute the auto-instrumentation
already sets.

```elixir
# ✅ semconv name for HTTP/DB (auto-emitted), myapp.* for business attrs
Tracer.set_attributes([{"my_app.org.id", org_id}, {"my_app.service", "video_provider"}])

# ❌ duplicating a semconv attribute under a custom name
Tracer.set_attribute("my_app.http_status", 200)   # http.response.status_code already set
```

> Sources: [OTel semantic conventions](https://opentelemetry.io/docs/specs/semconv/),
> [HTTP span conventions](https://opentelemetry.io/docs/specs/semconv/http/http-spans/).

---

## How to Instrument a Context Function

### Mutation (create/update/delete)

```elixir
def create_resource(scope, attrs) do
  MyApp.Telemetry.with_span "my_app.content.create_resource",
    %{"my_app.org.id" => scope.organization.id} do   # omit org attrs if not multi-tenant
    with {:ok, resource} <- do_create_resource(scope, attrs) do
      Events.broadcast(scope, {:resource_created, resource})
      Metrics.resource_created(scope.organization.id)
      {:ok, resource}
    end
  end
end
```

### Read (list/get)

```elixir
def list_resources(organization, opts \\ []) do
  MyApp.Telemetry.with_span "my_app.content.list_resources",
    %{"my_app.org.id" => organization.id, "page" => Keyword.get(opts, :page, 1)} do
    # ... query with pagination
  end
end
```

Read operations only need spans if they're complex (aggregations, multi-table
joins, filtered searches). A simple `Repo.get` does not need a custom span —
the Ecto auto-instrumentation covers it.

### External API call

```elixir
def create_upload_url(params) do
  key = Idempotency.key("create_upload", params.org_id, params.title)

  Tracer.with_span "my_app.video_provider.create_upload_url" do
    Tracer.set_attributes([
      {"my_app.service", "video_provider"},
      {"my_app.idempotency_key", key},
      {"my_app.org.id", params.org_id}
    ])

    case do_api_request(params, key) do
      {:ok, result} ->
        Tracer.set_attribute("http.status_code", 200)
        Metrics.external_api_call("video_provider", "create_upload_url", duration_ms, :ok)
        {:ok, result}

      {:error, reason} ->
        Tracer.set_status(:error, inspect(reason))
        Metrics.external_api_call("video_provider", "create_upload_url", duration_ms, :error)
        {:error, :external_api_error, reason}
    end
  end
end
```

---

## How to Instrument an Oban Worker

### Preferred: OpentelemetryOban

With `OpentelemetryOban.setup()` attached in `start/2`, job spans are created
and the trace context is propagated from the enqueuing request automatically —
**no manual inject/extract needed.** In the worker you only add business
attributes:

```elixir
defmodule MyApp.Workers.WebhookEventProcessor do
  use Oban.Worker, queue: :default

  require OpenTelemetry.Tracer, as: Tracer

  @impl true
  def perform(%Oban.Job{args: args, attempt: attempt}) do
    Logger.metadata(org_id: args["organization_id"])  # omit if not multi-tenant

    # OpentelemetryOban already opened the span and linked the parent trace;
    # just enrich it with business attributes.
    Tracer.set_attributes([
      {"my_app.org.id", args["organization_id"]},
      {"oban.attempt", attempt}
    ])

    # ... process job
  end
end
```

> Source: [OpentelemetryOban readme](https://hexdocs.pm/opentelemetry_oban/readme.html).

### Low-level reference: manual propagation

Only needed if you are **not** using `OpentelemetryOban` (e.g. a custom
job runner). Inject the context on enqueue and extract it in the worker.

#### Propagate trace context when enqueuing

```elixir
def enqueue(scope, worker_module, args) do
  trace_ctx = :otel_propagator_text_map.inject(:otel_ctx.get_current(), [])

  args
  |> Map.put(:trace_context, Map.new(trace_ctx))
  |> worker_module.new()
  |> Oban.insert()
end
```

#### Restore context in the worker

```elixir
defmodule MyApp.Workers.WebhookEventProcessor do
  use Oban.Worker, queue: :default

  require OpenTelemetry.Tracer, as: Tracer

  @impl true
  def perform(%Oban.Job{args: args, attempt: attempt}) do
    # Restore parent trace context
    if ctx = args["trace_context"] do
      :otel_propagator_text_map.extract(ctx)
    end

    # Set Logger metadata for structured logs
    Logger.metadata(org_id: args["organization_id"])  # omit if not multi-tenant

    Tracer.with_span "my_app.worker.webhook_event_processor",
      %{"my_app.org.id" => args["organization_id"], "oban.attempt" => attempt} do
      # ... process job
    end
  end
end
```

---

## How to Emit Metrics

### When to emit

Emit a metric when something happens that you'd want to count, track over
time, or alert on. Key signals:

| Event | Metric call |
|---|---|
| Resource viewed | `Metrics.resource_viewed(org_id, resource_id)` |
| Upload initiated | `Metrics.upload_initiated(org_id)` |
| Subscription created | `Metrics.subscription_created(org_id, plan)` |
| Subscription canceled | `Metrics.subscription_canceled(org_id, plan)` |
| Webhook delivered | `Metrics.webhook_delivered(org_id, event_type, status)` |
| External API call | `Metrics.external_api_call(service, op, duration, status)` |
| Payment failed | `Metrics.payment_failed(org_id, reason)` |
| Record imported | `Metrics.record_imported(org_id)` |
| Record converted | `Metrics.record_converted(org_id)` |

Adapt the table to your domain. The pattern — one metric per significant
business event — is universal.

### How to emit

Use `MyApp.Metrics` module. Every function emits a `:telemetry` event:

```elixir
MyApp.Metrics.resource_viewed(org_id, resource_id)
```

### Adding new metrics

When a new feature introduces a business-significant event:

1. Add a function to `MyApp.Metrics` that calls `:telemetry.execute/3`
2. Add the event to the handler list in `MyApp.TelemetryHandler.setup/0`
3. Add a test that verifies the telemetry event is emitted

---

## Structured Logging Rules

### Always use Logger with metadata, not string interpolation

```elixir
# ✅ CORRECT — structured, searchable, parseable
Logger.info("Resource created",
  resource_id: resource.id,
  org_id: org.id,
  external_id: resource.external_provider_id
)

# ❌ WRONG — string interpolation, not searchable
Logger.info("Resource #{resource.id} created for org #{org.id}")
```

### Log levels

- `debug` — detailed trace information, query params, idempotency keys
- `info` — business events (resource created, subscriber joined, webhook delivered)
- `warning` — recoverable issues (retry triggered, rate limit approaching, stale cache)
- `error` — failures requiring attention (external API error, payment failed, webhook delivery exhausted retries)

### What to log at each lifecycle point

**Context function entry (debug):**
```elixir
Logger.debug("Creating resource", org_id: org.id, title: attrs[:title])
```

**Context function success (info):**
```elixir
Logger.info("Resource created", resource_id: resource.id, org_id: org.id)
```

**Context function failure (warning or error):**
```elixir
Logger.warning("Resource creation failed", org_id: org.id, reason: inspect(reason))
```

**External API call (info on success, error on failure):**
```elixir
Logger.info("Upload URL created", org_id: org.id, duration_ms: elapsed)
Logger.error("External API error", org_id: org.id, status: 503, body: truncated_body)
```

**Oban worker start (info):**
```elixir
Logger.info("Processing webhook event", org_id: org_id, event_type: type)
```

---

## Logger Metadata Setup

### In plugs (HTTP requests)

A `SetRequestContext` plug sets:
- `request_id` (from Phoenix)
- `org_id` (from resolved organization, if multi-tenant)
- `user_id` (from authenticated user)
- `org_slug` (for human-readable filtering, if multi-tenant)

The `opentelemetry_logger_metadata` dependency auto-injects the current trace
context into Logger metadata for every log line within a span — no manual
plumbing:
- `otel_trace_id`
- `otel_span_id`

For Datadog log/trace correlation, use the `opentelemetry_logger_metadata_datadog`
variant, which formats the IDs the way Datadog expects.

> Sources: [opentelemetry_logger_metadata](https://hexdocs.pm/opentelemetry_logger_metadata/readme.html),
> [opentelemetry_logger_metadata_datadog](https://hexdocs.pm/opentelemetry_logger_metadata_datadog/readme.html).

### In Oban workers

Set at the start of every `perform/1`:

```elixir
Logger.metadata(
  org_id: args["organization_id"],
  worker: __MODULE__ |> Module.split() |> List.last()
)
```

### In GenServers (event subscribers)

Set when handling a message:

```elixir
def handle_info({:my_app_event, {_action, _resource}, scope}, state) do
  Logger.metadata(
    org_id: scope.organization && scope.organization.id,
    user_id: scope.user && scope.user.id
  )
  # ... handle event
  {:noreply, state}
end
```

---

## Testing Observability Code

### What to test

- `MyApp.Metrics` functions emit the correct `:telemetry` events with
  the correct measurements and metadata. Use `:telemetry_test.attach_event_handlers/2`.
- `MyApp.Telemetry.with_span/3` passes through return values unchanged —
  both success and error tuples.
- Custom instrumentation does not change the behavior of the wrapped function.

### What NOT to test

- Span creation and attributes — that's OpenTelemetry's responsibility.
- Auto-instrumentation behavior — that's the library maintainers' job.
- Log output format — too brittle, changes with formatter config.

---

## LiveView Spans and HTTP Attributes

LiveView spans do **not** carry HTTP semantic convention attributes
(`http.route`, `http.method`, `http.status_code`, `http.target`,
`http.scheme`). This is by design — LiveView operates over an existing
WebSocket connection, so there is no HTTP request/response cycle per mount
or event.

HTTP-level observability comes from the **initial page load** span, which is
a regular HTTP request instrumented by `OpentelemetryPhoenix`. Once the page
loads and the LiveView WebSocket connects, subsequent mounts and events
produce LiveView-specific spans instead.

### SpanEnrichment on_mount hook

`MyAppWeb.Hooks.SpanEnrichment` runs as the **last** `on_mount` hook in
every `live_session`. It enriches the current span with:

- `my_app.liveview.module` — the LiveView module name (e.g. `MyAppWeb.Admin.ResourceLive`)
- `my_app.liveview.connected` — `true` on connected mount, `false` on static render
- `my_app.org.id` — the current tenant's ID (if multi-tenant and resolved)
- `my_app.org.slug` — the current tenant's slug (if multi-tenant and resolved)
- `my_app.user.id` — the current user's ID (if authenticated)

This hook must always be listed **after** `AssignScope` (or equivalent)
in the `on_mount` list so that `current_scope` is populated.

### LiveView streams

Stream operations (`stream/3`, `stream_insert/3`, `stream_delete/2`) run inside
`handle_event/3` or `handle_info/2`, which are already covered by the
`OpentelemetryPhoenix` LiveView spans — no extra span is needed. For
high-cardinality streams where item count or render latency matters, optionally
emit a custom metric via `MyApp.Metrics` (e.g. count of items streamed,
time-to-insert) rather than adding per-item spans.

> Sources: [LiveView 1.1 released](https://www.phoenixframework.org/blog/phoenix-liveview-1-1-released),
> [Phoenix streams dev blog](https://fly.io/phoenix-files/phoenix-dev-blog-streams/).

### TelemetryOrgPlug for controller requests

`MyAppWeb.Plugs.TelemetryOrgPlug` runs in the organization pipeline after
`SetOrganization` (if multi-tenant). It sets `my_app.org.id`,
`my_app.org.slug`, and `my_app.user.id` on the current span for all
non-LiveView HTTP requests that resolve an organization (or authenticated
user context).

---

## External Service Span Conventions

All calls to an external service (e.g. a media/video provider, a payment
provider, or an S3-compatible object store) produce spans named
`my_app.<service>.<operation>`. The client module instruments every call
with:

| Attribute | Description |
|---|---|
| `my_app.service` | Short service identifier (e.g. `"video_provider"`) |
| `my_app.<service>.operation` | The operation name (e.g. `"create_direct_upload"`) |
| `my_app.org.id` | Tenant ID, read from Logger metadata (if multi-tenant) |
| `http.status_code` | HTTP status on success |
| `duration_ms` | Client-side latency in milliseconds |

On error, the span status is set to `:error` with the reason.

### Filtering service spans in your observability backend

```
# Grafana / Tempo TraceQL examples (adapt service.name to your app)
{resource.service.name="my_app" && span.my_app.service = "video_provider"}
{resource.service.name="my_app" && span.my_app.service = "video_provider" && duration > 500ms}
{resource.service.name="my_app" && span.my_app.video_provider.operation = "create_direct_upload"}
```

---

## Oban Worker Tenant Attribution

Every Oban worker that has `organization_id` in its args **must** call
`Tracer.set_attributes([{"my_app.org.id", org_id}])` at the start of
`perform/1`. This enables per-tenant filtering of background job traces.
(Skip if not multi-tenant.)

```elixir
def perform(%Oban.Job{args: %{"organization_id" => org_id} = _args}) do
  Logger.metadata(org_id: org_id)
  Tracer.set_attributes([{"my_app.org.id", org_id}])
  # ... rest of worker logic
end
```

Workers that resolve `org_id` during processing (e.g. a webhook processor
that reads it from event metadata) should set the attribute as soon as the
`org_id` is known.

---

## New Feature Checklist

When adding a new feature, verify:

- [ ] Context mutations wrapped in `MyApp.Telemetry.with_span/3`
- [ ] Span name follows `my_app.<context>.<operation>` convention
- [ ] Span attributes include `my_app.org.id` for tenant-scoped operations (if multi-tenant)
- [ ] External API calls produce spans with service, status, and idempotency key
- [ ] Oban workers restore trace context and set Logger metadata
- [ ] Business-significant events emit metrics via `MyApp.Metrics`
- [ ] New metrics added to `TelemetryHandler.setup/0` event list
- [ ] Logger calls use structured metadata, not string interpolation
- [ ] Error paths set span status to `:error` with reason
