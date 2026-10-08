# Optional external services

No external client or credentials are installed by this scaffold. When needed,
wrap a provider SDK or HTTP library in one client with a small explicit contract.
Inject a test double at that boundary; domain services must not call vendor SDKs
throughout the app. Translate expected provider outcomes to stable Result tags.

Set connection/read timeouts, bound retries and honor applicable retry guidance.
Retry mutations only when safe: generate one stable idempotency key per logical
operation, persist it as needed and reuse it on every retry. A random new key on
each retry defeats deduplication. Do not keep network calls inside SQLite writes.

Verify webhook signatures against exact raw request bytes before trusting data.
Enforce timestamp/replay limits according to the provider contract. Deduplicate
provider event IDs with a unique database constraint and commit the local change
and processing record atomically. If asynchronous processing is required, persist
an outbox/queue entry before acknowledging durable receipt; a notification or
in-memory thread is not durable delivery.

Secrets come from runtime configuration, never source, images or logs. Log only
safe identifiers, statuses and durations. Scope all resource lookup by the
resolved tenant when multi-tenant; never trust provider metadata alone as auth.

Test successful operations, expected provider errors, timeouts, duplicate/out-of-
order events and invalid signatures with local fixtures. Normal tests make no
real vendor requests. See `payment-integration.md` and `object-storage-integration.md`.
