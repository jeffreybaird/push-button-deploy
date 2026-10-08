# Observability

The scaffold uses Rails logging and ActiveSupport notifications. It does not
install an OpenTelemetry SDK, exporter, collector, metrics backend or job system.

Notes mutations write a minimal durable AuditLog inside their transaction and
emit `notes.created` / `notes.archived` with `{ note_id: id }` only after all open
transactions commit. Audit and instrumentation have different guarantees:
notifications are synchronous in-process observations, not durable messages.
Never rely on a subscriber to perform required audit or billing work.

Use stable operation names and structured identifiers for correlation. Do not
log note titles, request bodies, credentials, payment details, signed URLs,
emails or raw vendor error payloads. Filter sensitive request parameters before
adding new inputs. Keep error types and bounded status metadata useful without
copying secrets. Logs should distinguish expected rejection from system failure.

If tracing becomes necessary, use maintained Rails/Active Record instrumentation
for their layers, then add manual spans for domain orchestration and unwrapped
external calls. Avoid duplicate spans, high-cardinality metric labels and
unbounded payloads. Configure endpoints and credentials at runtime.

Test event identity, payload privacy and commit/rollback timing. A subscriber
exception after commit must remain an exception; never pretend the persisted
operation rolled back. For critical delivery use an atomic outbox and idempotent
consumer. See `architecture-decisions.md` and `external-service-integration.md`.
