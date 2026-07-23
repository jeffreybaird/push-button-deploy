# Object Storage Integration

> **Optional module.** Include if your app stores files/blobs in object storage.

Direct-browser uploads to an S3-compatible object store — **file bytes never pass
through Puma**. The browser PUTs straight to the bucket; the app only mints a
short-lived credential and records the resulting key. Works with AWS S3,
Cloudflare R2, DigitalOcean Spaces, and MinIO (all speak the S3 API).

This follows the base pattern in `external-service-integration.md`: one flat
client class in `app/clients/`, injected so specs can stub it; secrets via
`ENV.fetch`. There is **no Active Storage** here — that is Rails. You wire the
pieces yourself, which is a few dozen lines and buys you full control of keys.

> **Baseline:** Direct-to-bucket presigned uploads — bytes never transit Puma · one `StorageClient` in `app/clients/` returning dry-monads `Success`/`Failure` · store only the object **key + metadata** in SQLite, **never the blob** (single-writer + Litestream) · private objects read via short-lived presigned GET · content-type and size validated at the edge and re-checked on confirm · secrets via `ENV.fetch`.

---

## Choosing the storage layer

| Approach | When | Notes |
|---|---|---|
| [`aws-sdk-s3`](https://github.com/aws/aws-sdk-ruby) `~> 1` (default) <span title="stable">`[stable]`</span> | Almost always | Full S3 surface — presign PUT/POST/GET, HEAD, multipart, lifecycle, delete. Wrap behind one flat `StorageClient`. |
| [`shrine`](https://github.com/shrinerb/shrine) `~> 3` <span title="stable">`[stable]`</span> | You want attachment lifecycle (validation, derivatives, promotion) managed for you | Plugin-based; more machinery than a lean app needs, but batteries included. |
| A hand-rolled SigV4 signer over `Net::HTTP`/Faraday | You genuinely cannot add `aws-sdk-s3` | You sign presigned URLs yourself. Only worth it to shed a dependency; easy to get wrong. |

**Default to `aws-sdk-s3` wrapped in `StorageClient`.** There is no framework
default to fall back on (no Active Storage), so the client class *is* the
integration. Pick one approach — don't run two side by side.

> **Reuse the deploy's DO Spaces.** The `push-button-deploy` stack already talks
> to DigitalOcean Spaces (S3-compatible) — Litestream streams the SQLite WAL
> there for DR (`.claude/database.md`). App uploads can reuse the **same Spaces
> account, region, and endpoint**; use a **separate bucket** for user uploads so
> your files and your database replica have independent lifecycles and access
> policies.

---

## Presigned / Direct Uploads — the core principle

The browser uploads **directly to the bucket**. Puma only mints a short-lived
credential (a local crypto operation — no network round-trip) and, afterward,
records the key. Bytes never transit the app server.

```
Browser                     Puma (App)                  Bucket (Spaces/S3/R2)
  |                            |                              |
  |-- POST .../sign ---------->|                              |
  |                            |  presign PUT (local, no I/O) |
  |<-- { url, key } -----------|                              |
  |-- PUT <signed-url> (file) ------------------------------->|
  |<-- 200 OK -----------------------------------------------|
  |-- POST .../confirm ------->|  HEAD object, persist row    |
  |                            |----- head_object ----------->|
  |<-- { attachment_id } ------|  (key + metadata -> SQLite)  |
```

### The client — one flat class in `app/clients/`

All S3 access goes through `StorageClient`. No route, service, or model touches
`Aws::S3` directly. Presign methods are local (no network); `head`/`delete` hit
S3, so they carry an OpenTelemetry span and map failures to tagged Results — same
contract as every other client (`external-service-integration.md`).

```ruby
# app/clients/storage_client.rb
require "aws-sdk-s3"
require "dry/monads"
require "securerandom"
require "opentelemetry"

class StorageClient
  include Dry::Monads[:result]

  PUT_EXPIRY = 900   # 15 min — covers pick-file -> PUT-complete
  GET_EXPIRY = 300   # 5 min  — private read link
  MAX_BYTES  = 25 * 1024 * 1024
  TRACER     = OpenTelemetry.tracer_provider.tracer("my_app")

  def initialize(s3: nil)
    @s3 = s3 || Aws::S3::Resource.new(
      region:            ENV.fetch("STORAGE_REGION"),
      endpoint:          ENV["STORAGE_ENDPOINT"],   # set for Spaces/R2/MinIO; omit for AWS
      access_key_id:     ENV.fetch("STORAGE_ACCESS_KEY_ID"),
      secret_access_key: ENV.fetch("STORAGE_SECRET_ACCESS_KEY")
    )
  end

  # Short-lived URL the browser PUTs to directly. Binds content_type; cannot cap
  # size (see presigned_post for that). Local operation — no span, no I/O.
  def presigned_put_url(key:, content_type:, expires_in: PUT_EXPIRY)
    obj = @s3.bucket(bucket).object(key)
    Success(obj.presigned_url(:put, expires_in:, content_type:))
  rescue Aws::Errors::ServiceError => e
    Failure([:external_service_error, e.message])
  end

  # Size-capped alternative: browser POSTs a multipart form with these fields.
  # content_length_range makes the BUCKET reject an over-size upload at the edge.
  def presigned_post(key:, content_type:, max_size: MAX_BYTES)
    post = @s3.bucket(bucket).presigned_post(
      key:,
      content_type:,
      content_length_range: 0..max_size,
      success_action_status: "201"
    )
    Success({ url: post.url, fields: post.fields })
  rescue Aws::Errors::ServiceError => e
    Failure([:external_service_error, e.message])
  end

  # Short-lived read URL for a PRIVATE object. Local operation.
  def presigned_get_url(key:, expires_in: GET_EXPIRY)
    Success(@s3.bucket(bucket).object(key).presigned_url(:get, expires_in:))
  end

  # Network: confirm the object the browser PUT actually landed, read its real
  # size/type/etag. Trust the bucket's numbers, not the browser's claims.
  def head(key:)
    TRACER.in_span("storage.head", kind: :client) do |span|
      span.set_attribute("peer.service", "object-storage")
      res = @s3.client.head_object(bucket:, key:)
      Success(content_type: res.content_type, content_length: res.content_length, etag: res.etag)
    end
  rescue Aws::S3::Errors::NotFound, Aws::S3::Errors::NoSuchKey
    Failure([:not_found])
  rescue Aws::Errors::ServiceError => e
    Failure([:external_service_error, e.message])
  end

  def delete(key:)
    TRACER.in_span("storage.delete", kind: :client) do
      @s3.bucket(bucket).object(key).delete
      Success(:ok)
    end
  rescue Aws::Errors::ServiceError => e
    Failure([:external_service_error, e.message])
  end

  # Predictable, collision-safe, unguessable — see Key Layout below.
  def self.key_for(account:, kind:, filename:)
    ext = File.extname(filename).delete(".").downcase
    "account/#{account.id}/#{kind}/#{SecureRandom.uuid}.#{ext}"
  end

  private

  def bucket = ENV.fetch("STORAGE_BUCKET")
end
```

Inject it (`client: StorageClient.new`) into services so a spec passes a double,
exactly as `external-service-integration.md` prescribes.

### The routes — thin, on `App`

Two endpoints: **sign** (mint the credential) and **confirm** (record the key
after the browser's PUT succeeds). Both parse params, call the domain layer, and
render. No S3 calls, no business rules in the route. (`json` here is the helper
from `sinatra/json`.)

```ruby
# app/routes/attachments.rb — registered on App, or inline in app.rb

# 1. Mint a presigned PUT for a tenant-scoped key
post "/notes/:id/attachments/sign" do
  note = Note[params[:id]] or halt 404
  authorize! note, :update?                              # policy object — see rbac.md
  key  = StorageClient.key_for(account: Current.account, kind: "attachment",
                               filename: params[:filename])
  case StorageClient.new.presigned_put_url(key:, content_type: params[:content_type])
  in Success(url)                         then json(url:, key:)
  in Failure([:external_service_error, _]) then halt 502, { error: "storage_unavailable" }.to_json
  end
end

# 2. Persist the key + metadata AFTER the browser finishes its PUT
post "/notes/:id/attachments/confirm" do
  note = Note[params[:id]] or halt 404
  authorize! note, :update?
  case Attachments::Attach.call(record: note, key: params[:key])
  in Success(attachment)             then json(attachment_id: attachment.id)
  in Failure([:validation, errors])  then halt 422, { errors: errors.full_messages }.to_json
  in Failure([:not_found])           then halt 422, { error: "upload_missing" }.to_json
  in Failure([:external_service_error, _]) then halt 502, { error: "storage_unavailable" }.to_json
  end
end
```

---

## Store the key, never the blob

Persist only the object **key** (plus metadata) in SQLite — **never the file
bytes**. This is not a style preference; the backend forces it. See
`.claude/database.md`.

- **Single writer.** Every write locks the *whole* database file. A
  multi-megabyte BLOB insert holds that lock for the length of the write, stalling
  every other writer app-wide. Large blobs in SQLite are the single-writer
  anti-pattern this stack most wants you to avoid.
- **Litestream.** The SQLite file is continuously streamed to DO Spaces by
  Litestream. Blobs in the DB bloat every WAL frame and every restore — you'd be
  shoving the files through the replication path as database pages. Keep the DB
  small; put the files in the bucket Litestream is already sitting next to.
- **Disaster recovery.** A lean DB restores in seconds on a fresh droplet. A DB
  fat with blobs does not — and DR speed is the whole point of the SQLite backend.

So the bytes live in object storage and the row in `attachments` holds the key,
content type, size, and checksum. Different lifecycles, different stores.

### The `attachments` table

A single polymorphic-ish table points any record at its blobs. Sequel has no
`belongs_to :polymorphic`, so it's `record_type` + `record_id` columns and a
hand-rolled lookup — plain Sequel, no gem.

```ruby
# db/migrate/012_create_attachments.rb
Sequel.migration do
  change do
    create_table(:attachments) do
      primary_key :id
      String   :record_type,  null: false     # e.g. "Note"
      Integer  :record_id,    null: false
      String   :key,          null: false      # the S3 object key — NOT the bytes
      String   :content_type, null: false
      Integer  :byte_size,    null: false
      String   :checksum                        # S3 ETag (MD5 for single-part PUT)
      DateTime :created_at,   null: false
      DateTime :updated_at
      index %i[record_type record_id]           # fetch a record's attachments
      index :key, unique: true                  # one row per object
    end
  end
end
```

```ruby
# app/models/attachment.rb
class Attachment < Sequel::Model
  MAX_BYTES     = 25 * 1024 * 1024
  CONTENT_TYPES = %w[image/png image/jpeg image/webp application/pdf].freeze

  def validate
    super
    validates_presence %i[record_type record_id key content_type byte_size]
    validates_includes CONTENT_TYPES, :content_type
    validates_max_length 1024, :key
    if byte_size && byte_size > MAX_BYTES
      errors.add(:byte_size, "exceeds #{MAX_BYTES} bytes")
    end
  end

  # Hand-rolled polymorphic target (no Rails polymorphic association here).
  def record = Object.const_get(record_type)[record_id]

  # Callers ask the client for a fresh short-lived read URL; never store one.
  def download_url(client: StorageClient.new, expires_in: StorageClient::GET_EXPIRY)
    client.presigned_get_url(key:, expires_in:)
  end
end
```

```ruby
# app/models/note.rb — the owning record fetches its blobs by (type, id)
class Note < Sequel::Model
  def attachments = Attachment.where(record_type: "Note", record_id: id)
end
```

### The confirm service — validate against the bucket, then a short write

`Attachments::Attach` HEADs the object (trusting the bucket's real size/type over
the browser's claims), validates, then writes. Note the shape: the S3 round-trip
happens **before** `DB.transaction`, so the write lock is held only for the insert
— the single-writer rule from `.claude/database.md`.

```ruby
# app/services/attachments/attach.rb
module Attachments
  class Attach
    include Dry::Monads[:result]

    def self.call(...) = new(...).call

    def initialize(record:, key:, client: StorageClient.new)
      @record, @key, @client = record, key, client
    end

    def call
      meta = @client.head(key: @key)          # network I/O — OUTSIDE the transaction
      return meta if meta.failure?             # :not_found (browser never PUT) or storage error
      info = meta.value!

      attachment = Attachment.new(
        record_type:  @record.class.name,
        record_id:    @record.id,
        key:          @key,
        content_type: info[:content_type],
        byte_size:    info[:content_length],
        checksum:     info[:etag]
      )
      return Failure([:validation, attachment.errors]) unless attachment.valid?

      DB.transaction { attachment.save }       # short write, no external I/O inside
      Success(attachment)
    end
  end
end
```

---

## Validation & virus scanning

Never trust the browser about content type or size — it controls both the request
and the claimed metadata. Validate at two points:

1. **At the edge (optional but preferred):** use `presigned_post` with
   `content_length_range` so the bucket itself rejects an over-size upload. A plain
   presigned `PUT` binds `content_type` but **cannot cap size** — the bucket
   accepts whatever the browser sends.
2. **On confirm (always):** `head` the object and validate the bucket's real
   `content_length` and `content_type` against your allowlist (the `Attachment`
   validation above). If it fails, delete the orphan and return `Failure`.

```ruby
# reject-and-clean-up on an over-size / wrong-type object
unless attachment.valid?
  @client.delete(key: @key)                    # don't leave an orphan in the bucket
  return Failure([:validation, attachment.errors])
end
```

**Virus scanning (hook).** Content-type/size checks are not malware checks. If you
accept untrusted files (anything a user other than the uploader can download),
scan before serving:

- Mark the row unscanned (`scanned_at NULL`); only mint a `presigned_get_url` for
  scanned rows.
- Scan out-of-band. The scaffold has no job runner by default; a **Sidekiq** worker
  (see `external-service-integration.md`) running ClamAV (`clamd`) is the durable
  option — `delete` + flag on a hit, set `scanned_at` on a pass. Enqueue it from
  `DB.after_commit`, never inside the write transaction.

---

## Key Layout

Use a predictable, collision-safe, unguessable structure:

```
account/<id>/<kind>/<uuid>.<ext>
```

```
account/42/attachment/550e8400-e29b-41d4-a716-446655440000.png
```

- `account/<id>` — namespaces by tenant (no cross-tenant key collision)
- `<kind>` — asset type (`attachment`, `avatar`, `cover`, …)
- `<uuid>` — generated server-side; unguessable, no name collisions

`StorageClient.key_for` (above) builds it. Because there is **no Active Storage
generating keys for you**, you own this layout outright — the key you sign is the
key you store in `attachments.key` is the key you HEAD on confirm. One value, one
meaning, end to end.

---

## Public vs Private Buckets

| Bucket | Use case | Read access |
|---|---|---|
| **Public** | Images, thumbnails, static assets | Object URL is directly shareable; no signing to read |
| **Private** | Documents, user data, anything sensitive | Mint a **presigned GET** server-side, short expiry |

```ruby
# Private read — short-lived signed GET, never a permanent public URL, never stored
result = StorageClient.new.presigned_get_url(key: attachment.key, expires_in: 300)
```

Default presigned lifetime: **15 minutes (900 s)** for PUT, **5 minutes (300 s)**
for private GET. Raise the PUT expiry only for genuinely large uploads on slow
links. Default user content to **private** — a presigned GET per view is cheap,
and it keeps `Current.account` scoping meaningful instead of leaking a permanent
public URL.

---

## CORS (required for direct upload)

Because the browser PUTs to the bucket host (a different origin from your app), the
bucket needs a CORS policy or the preflight `OPTIONS` fails.

```json
[
  {
    "AllowedOrigins": ["https://app.example.com", "http://localhost:9292"],
    "AllowedMethods": ["PUT", "POST", "GET", "HEAD"],
    "AllowedHeaders": ["*"],
    "ExposeHeaders": ["ETag"],
    "MaxAgeSeconds": 3000
  }
]
```

**Debugging:** DevTools → Network → find the `OPTIONS` preflight to the bucket
host. A missing `Access-Control-Allow-Origin` in the response means the bucket
rejected the preflight — fix `AllowedOrigins` (include your local Puma origin,
e.g. `http://localhost:9292`). For a presigned `POST`, the `Content-Type` header
must be permitted; for a `PUT`, so must the `Content-Type` you bound into the
signature. On DO Spaces this is set per-bucket in the control panel or via the S3
`PutBucketCors` API.

---

## Secrets

Provider credentials come from the environment, never source. There are no Rails
encrypted credentials here — `ENV.fetch` only (dev/test via `dotenv`; production
injected into the container by the `push-button-deploy` pipeline).

| Variable | Required | Example | Purpose |
|---|---|---|---|
| `STORAGE_ACCESS_KEY_ID` | Yes | `DO00…` | Access key |
| `STORAGE_SECRET_ACCESS_KEY` | Yes | `wJalr…` | Secret |
| `STORAGE_BUCKET` | Yes | `my-app-uploads` | Bucket for user uploads (separate from the Litestream replica bucket) |
| `STORAGE_REGION` | Yes | `us-east-1` | Region (Spaces signs against `us-east-1`) |
| `STORAGE_ENDPOINT` | For Spaces/R2/MinIO | `https://nyc3.digitaloceanspaces.com` | S3-compatible endpoint (omit for AWS) |

```ruby
# ❌ secret in source
secret_access_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"

# ✅ from the environment, fail loud if missing
secret_access_key: ENV.fetch("STORAGE_SECRET_ACCESS_KEY")
```

The deploy already holds DO Spaces credentials for Litestream; reuse the same
account/region/endpoint for uploads, but keep the **upload bucket distinct** from
the DB-replica bucket. Never commit credentials; `.env` is gitignored.

---

## Testing

Specs **never touch a real bucket.** Inject and stub `StorageClient`; block stray
S3 calls with WebMock so a leak fails loudly. Each example runs inside a Sequel
transaction rolled back afterward (see `testing.md`).

### Stub the client at the sign endpoint

```ruby
RSpec.describe "POST /notes/:id/attachments/sign", type: :request do
  include Rack::Test::Methods
  def app = App

  it "returns a presigned PUT url for a tenant-scoped key" do
    client = instance_double(StorageClient)
    allow(StorageClient).to receive(:new).and_return(client)
    allow(client).to receive(:presigned_put_url)
      .and_return(Success("https://bucket.example.com/key?X-Amz-Signature=abc"))

    post "/notes/#{note.id}/attachments/sign", filename: "a.png", content_type: "image/png"

    expect(last_response.status).to eq(200)
    expect(JSON.parse(last_response.body)["url"]).to include("X-Amz-Signature")
  end
end
```

### The confirm service — stub `head`, assert the persisted row

```ruby
RSpec.describe Attachments::Attach do
  it "records the key + bucket-reported metadata" do
    client = instance_double(StorageClient)
    allow(client).to receive(:head)
      .and_return(Success(content_type: "image/png", content_length: 2048, etag: '"abc"'))

    result = described_class.call(record: note, key: "account/1/attachment/uuid.png", client:)

    expect(result).to be_success
    a = result.value!
    expect(a.byte_size).to eq(2048)
    expect(a.content_type).to eq("image/png")
    expect(note.attachments.count).to eq(1)
  end

  it "rejects an over-size object and deletes the orphan" do
    client = instance_double(StorageClient)
    allow(client).to receive(:head)
      .and_return(Success(content_type: "image/png", content_length: 999_000_000, etag: '"x"'))
    allow(client).to receive(:delete).and_return(Success(:ok))

    result = described_class.call(record: note, key: "account/1/attachment/big.png", client:)

    expect(result).to be_failure
    expect(client).to have_received(:delete).with(key: "account/1/attachment/big.png")
  end
end
```

### Block real S3

```ruby
# spec/spec_helper.rb
WebMock.disable_net_connect!(allow_localhost: true)   # any stray S3 call now raises
```

Never store the blob bytes in a spec fixture DB either — the "no blobs in SQLite"
rule holds in tests too; use `instance_double(StorageClient)` returning metadata.

---

## Cross-References

| Topic | File |
|---|---|
| Base client pattern (one flat client, inject + stub) | `external-service-integration.md` |
| **Why no blobs in SQLite** — single writer, WAL, Litestream, DR | `database.md` |
| Result tuples, events, audit | `architecture-decisions.md` |
| Where storage calls belong (route vs service vs model) | `separation-of-concerns.md` |
| Authorization on sign/confirm (`authorize!`, policy objects) | `rbac.md` |
| OTel spans, structured logging | `observability.md` |
| Testing patterns, transaction rollback | `testing.md` |
