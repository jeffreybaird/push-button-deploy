# Scalability

Begin with the measured workload. This scaffold uses one SQLite file, one app
host and ordinary server-rendered requests; it has no Redis, durable job runner,
shared cache, realtime channel or read replica.

Keep Active Record transactions short, queries indexed and lists paginated.
Use eager loading for actual associations to avoid N+1, and inspect query plans
for hot paths. SQLite WAL allows readers alongside a writer but does not create
multiple concurrent writers or eliminate every lock condition. Litestream is
recovery infrastructure, not a queryable replica.

Batch high-volume noncritical work when measurements justify it. State the
loss and retry semantics of any buffer before using one; do not put billing or
audits in a lossy in-memory buffer. Slow external work should use a deliberately
chosen durable queue/outbox architecture, with bounded retries and idempotency.
No queue backend is implied by the Rails gem dependency.

Cache only when there is a real bottleneck and an invalidation plan. Include
tenant and version boundaries where applicable. A process-local cache is not
shared across Puma workers. Adding Solid Cache/Queue database files would need
explicit backup and deployment changes to the current single-file contract.

Keep public pages connection-free unless realtime is required. Small JavaScript
enhancements must preserve server behavior. Apply rate limits to actual abuse
surfaces with an appropriate shared store and trusted proxy configuration; do not
blindly trust arbitrary forwarded IP headers. Separate future critical/bulk work
and measure queue depth, latency and contention before expanding infrastructure.
