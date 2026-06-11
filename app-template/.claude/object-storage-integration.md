# Object Storage Integration

> **Optional module.** Include if your app stores files/blobs in object storage.

This module covers direct-browser uploads (presigned PUT URLs) to an S3-compatible object store (e.g. AWS S3, DigitalOcean Spaces, Cloudflare R2, MinIO). No file bytes ever pass through your Phoenix server.

See `external-service-integration.md` for the base pattern (behaviour + Mox + config-injected client) that this module follows.

## Choosing the S3 library

Two community options; either sits behind the same `MyApp.Storage.Client` behaviour, so the choice never leaks past the client.

| Library | Version | Best for | Trade-off |
| --- | --- | --- | --- |
| [`req_s3`](https://hexdocs.pm/req_s3/ReqS3.html) | `~> 0.2` | Presigned URLs + basic `put`/`get`/`delete` | Lighter, Req-native ([why a Req plugin](https://dashbit.co/blog/sdks-with-req-s3)); narrower API surface |
| [`ex_aws_s3`](https://hexdocs.pm/ex_aws_s3/ExAws.S3.html) | `~> 2.5` | Multipart uploads, lifecycle rules, broad AWS surface | Heavier dependency tree |

The examples below use ExAws (`~> 2.5`) because it covers the full surface; if you only need presign + simple object ops, `req_s3` is a lighter fit. Pick one — don't mix both in the same client.

## Relevant files

- `lib/my_app/storage.ex` — the context (public API)
- `lib/my_app/storage/client_behaviour.ex` — the mockable contract
- `lib/my_app/storage/client.ex` — the real client (wraps `ex_aws_s3`)
- `lib/my_app_web/live/upload_handlers.ex` — shared LiveView upload macro (if applicable)
- `assets/js/hooks/storage_uploader.ts` — JS hook that PUTs directly to the bucket

## Environment variables

Set at runtime only (`config/runtime.exs`). Never commit credentials.

| Variable | Required | Example | Purpose |
| --- | --- | --- | --- |
| `STORAGE_ACCESS_KEY_ID` | yes (non-test) | `AKIAIOSFODNN7EXAMPLE` | Provider access key |
| `STORAGE_SECRET_ACCESS_KEY` | yes (non-test) | `wJalrXUtnFEMI/K7MDENG/…` | Matching secret |
| `STORAGE_BUCKET` | yes | `my-app-assets` | Bucket name |
| `STORAGE_REGION` | yes | `us-east-1` | Region (e.g. `us-east-1`, `nyc3`, `auto`) |
| `STORAGE_HOST` | yes | `s3.amazonaws.com` | S3-compatible endpoint host |
| `STORAGE_PUBLIC_URL_BASE` | no | `https://cdn.example.com` | Override when a CDN sits in front of the bucket |

## Client behaviour + implementation

```elixir
# lib/my_app/storage/client_behaviour.ex
defmodule MyApp.Storage.ClientBehaviour do
  @moduledoc "Mockable contract for S3-compatible object storage."

  @callback presigned_put_url(bucket :: String.t(), key :: String.t(), opts :: keyword()) ::
              {:ok, String.t()} | {:error, term()}

  @callback delete_object(bucket :: String.t(), key :: String.t()) ::
              :ok | {:error, term()}
end
```

```elixir
# lib/my_app/storage/client.ex
defmodule MyApp.Storage.Client do
  @moduledoc "Real client. Wraps ex_aws_s3."
  @behaviour MyApp.Storage.ClientBehaviour

  @impl true
  def presigned_put_url(bucket, key, opts \\ []) do
    expires_in = Keyword.get(opts, :expires_in, 900)
    config = aws_config()
    ExAws.S3.presigned_url(config, :put, bucket, key, expires_in: expires_in, virtual_host: true)
  end

  @impl true
  def delete_object(bucket, key) do
    bucket
    |> ExAws.S3.delete_object(key)
    |> ExAws.request(aws_config())
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp aws_config do
    ExAws.Config.new(:s3,
      access_key_id: System.fetch_env!("STORAGE_ACCESS_KEY_ID"),
      secret_access_key: System.fetch_env!("STORAGE_SECRET_ACCESS_KEY"),
      region: System.fetch_env!("STORAGE_REGION"),
      host: System.fetch_env!("STORAGE_HOST")
    )
  end
end
```

```elixir
# lib/my_app/storage.ex
defmodule MyApp.Storage do
  @moduledoc "Public API for object storage operations."

  @bucket System.get_env("STORAGE_BUCKET", "my-app-assets")

  defp client, do: Application.get_env(:my_app, :storage_client, MyApp.Storage.Client)

  @doc """
  Returns a presigned PUT URL for direct browser upload.

      iex> {:ok, url} = MyApp.Storage.presigned_put_url("uploads/abc123.png")
      iex> String.starts_with?(url, "https://")
      true
  """
  def presigned_put_url(key, opts \\ []) do
    client().presigned_put_url(@bucket, key, opts)
  end

  @doc """
  Deletes an object from the bucket.
  """
  def delete_object(key) do
    client().delete_object(@bucket, key)
  end

  @doc """
  Builds a public URL for a stored object.

      iex> MyApp.Storage.public_url("uploads/abc123.png")
      "https://my-app-assets.s3.amazonaws.com/uploads/abc123.png"
  """
  def public_url(key) do
    base = System.get_env("STORAGE_PUBLIC_URL_BASE") ||
           "https://#{@bucket}.#{System.get_env("STORAGE_HOST", "s3.amazonaws.com")}"
    "#{base}/#{key}"
  end
end
```

## Bucket key layout

Adopt a predictable, collision-safe key structure:

```
<scope>/<id>/<kind>/<uuid>.<ext>
```

Example for a multi-tenant app:

```
org/42/avatar/550e8400-e29b-41d4-a716-446655440000.png
```

- `<scope>/<id>` — namespace by resource (prevents cross-tenant access at storage level)
- `<kind>` — asset type (`avatar`, `cover`, `attachment`, …)
- `<uuid>` — generated server-side; makes keys unguessable and avoids name collisions

## Presigned URL flow

```
Browser                       Phoenix                    Storage
  |                              |                           |
  |-- POST /uploads/sign ------->|                           |
  |                              |-- presign_put_url() ----->|
  |                              |<-- signed URL ------------|
  |<-- { url, key } -------------|                           |
  |-- PUT <signed-url> (file) -------------------------------->|
  |<-- 200 OK ------------------------------------------------|
  |-- POST /uploads/confirm ---->|                           |
  |                              | (persist key to DB)       |
```

The Phoenix server only issues the URL and later confirms the key — no bytes flow through it.

## Bucket CORS policy

Because the browser PUTs directly to the bucket host, CORS must be configured on the bucket. Use virtual-hosted style URLs (`virtual_host: true` in `ExAws`) so the preflight `Origin` matches the bucket's CORS surface — path-style URLs will not get CORS headers back.

Example policy (JSON, adjust origins to match your app's domains):

```json
[
  {
    "AllowedOrigins": [
      "https://app.example.com",
      "http://localhost:4000"
    ],
    "AllowedMethods": ["PUT", "GET", "HEAD"],
    "AllowedHeaders": ["*"],
    "ExposeHeaders": ["ETag"],
    "MaxAgeSeconds": 3000
  }
]
```

**Debugging CORS failures:** open DevTools → Network, retry the upload, find the OPTIONS preflight to the bucket host. Check the request's `Origin` header against `AllowedOrigins`. A missing `Access-Control-Allow-Origin` response means the bucket rejected the preflight — update the policy.

**Dev tip:** if your app resolves tenants by subdomain (e.g. `http://<slug>.localhost:4000`), include that wildcard form. Some providers reject wildcards on non-TLD hosts; fall back to listing each subdomain explicitly, or use a dev-only bucket with `"AllowedOrigins": ["*"]`.

## Public vs private buckets

| Bucket type | Use case | Notes |
| --- | --- | --- |
| **Public** | Images, thumbnails, static assets | Object URL is directly shareable; no signing needed to read |
| **Private** | Documents, user data, anything sensitive | Generate a presigned GET URL server-side; set short expiry |

Private example:

```elixir
def presigned_get_url(key, expires_in \\ 300) do
  client().presigned_put_url(@bucket, key, expires_in: expires_in, method: :get)
end
```

## Presigned URL lifetime

Default: **15 minutes** (900 s). This covers the window between a user picking a file and the PUT completing. Raise this only if users routinely upload very large files on slow connections.

## Testing

Tests never touch real object storage. Configure a Mox stub in `config/test.exs`:

```elixir
# config/test.exs
config :my_app, :storage_client, MyApp.Storage.MockClient
```

```elixir
# test/support/mocks.ex
Mox.defmock(MyApp.Storage.MockClient, for: MyApp.Storage.ClientBehaviour)
```

```elixir
# in a test
import Mox

test "signs a presigned URL for the upload", %{} do
  expect(MyApp.Storage.MockClient, :presigned_put_url, fn _bucket, key, _opts ->
    {:ok, "https://fake-bucket.example.com/#{key}?X-Amz-Signature=abc"}
  end)

  assert {:ok, url} = MyApp.Storage.presigned_put_url("org/1/avatar/uuid.png")
  assert String.contains?(url, "X-Amz-Signature")
end
```

See `external-service-integration.md` for the full Mox setup and `payment-integration.md` for another example of the behaviour + mock pattern applied to an external service.
