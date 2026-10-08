# Optional payments

Billing is not installed. If required, use a maintained provider SDK behind the
client boundary described in `external-service-integration.md`. Prefer hosted
checkout and tokenization; do not handle raw card details in this application.

Persist provider identifiers and server-owned price/entitlement mappings. Never
trust a submitted amount, plan entitlement or success redirect as payment proof.
Verify signed webhook events, deduplicate event IDs with a database constraint
and update state transactionally. Account for duplicate and out-of-order delivery;
retrieve authoritative provider state where the event contract requires it.

Use a stable idempotency key for each charge/subscription operation across all
retries. Keep network calls outside database transactions; use durable state or
an outbox to coordinate local intent and external effects. ActiveSupport
notifications are not a billing queue and cannot guarantee delivery.

Audit meaningful state transitions without payment details or webhook bodies.
Separate billing-critical work from future bulk jobs, scope customer lookups to
the correct tenant, and authorize billing actions explicitly. Distinguish test
and production credentials and configure them only at runtime.

Test successful purchase and cancellation plus declined, duplicate, replayed,
invalid-signature and delayed events through a client double. Do not contact
live payment services from the normal quality gate.
