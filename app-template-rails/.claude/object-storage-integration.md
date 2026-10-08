# Optional object storage

The scaffold stores no uploads. Litestream's bucket is for database recovery,
not automatically an application file store. Container-local files are ephemeral.

For uploads, add an explicit storage configuration and authorization boundary.
Prefer short-lived signed direct-upload/download URLs after permission checks;
use server-generated unpredictable object keys. Scope metadata to the owner or
tenant, enforce size/content rules and validate actual file type where necessary.
A filename or content-type header alone is not trusted validation.

Keep sensitive objects private. Do not log signed URLs, tokens or raw contents.
Use separate least-privilege credentials and lifecycle/retention policies from
database backups. Avoid serving untrusted active content on the application's
trusted origin. Document cleanup for abandoned uploads and failed processing.

If adopting Active Storage, configure its migrations, storage service and any
processing libraries explicitly, audit current versions, and plan durable jobs
where needed. It is not enabled by the generated application railties. Do not
add local disk storage under an unbacked path and call it persistent.

Wrap storage operations in a testable client or the framework boundary. Test
successful upload/download authorization, missing objects, oversized/invalid
content, failed uploads and cross-tenant access without contacting live storage.
