defmodule Crysa.Storage.S3 do
  @moduledoc """
  S3-compatible (Cloudflare R2, AWS S3, MinIO) adapter for `Crysa.Storage`.

  Uses `Req` as the HTTP client and implements AWS Signature V4 signing
  manually so no additional `ExAws`/`hackney` dependency is required. The
  adapter is configured via environment variables / application config:

  - `:bucket` - R2/S3 bucket name (`R2_BUCKET_NAME` in Castra)
  - `:account_id` - Cloudflare account ID for R2 (`R2_ACCOUNT_ID`)
  - `:access_key_id` - (`R2_ACCESS_KEY_ID`)
  - `:secret_access_key` - (`R2_SECRET_ACCESS_KEY`)
  - `:endpoint_url` - Full S3 endpoint, e.g. `https://<account_id>.r2.cloudflarestorage.com`
  - `:region` - S3 region, defaults to `"auto"` for R2
  - `:cdn_base_url` - Public CDN base URL (`R2_DOMAIN_CDN_URL`), used to build public URLs

  When the bucket is not configured, `put/3` and `delete/1` return
  `{:error, :not_configured}` so callers can surface a clear error
  instead of silently discarding uploads. In `test`/`dev` the `Local`
  adapter is used by default.

  Bulk deletion is implemented as individual `DELETE` requests per key
  (idempotent) with a small concurrency limit. If the bucket supports
  `DeleteObjects` the XML batch path can be added later without changing
  the facade API.

  Reference Castra implementation: `backend/src/database/storage.rs`
  (`StorageClient::upload_image_file`, `delete_image_objects`,
  `extract_object_key_from_url`).
  """

  @behaviour Crysa.Storage.Adapter

  require Logger

  @impl true
  def put(key, data, opts) when is_binary(key) do
    with :ok <- validate_key_s3(key),
         {:ok, config} <- s3_config(),
         {:ok, body} <- read_body(data) do
      content_type = Keyword.get(opts, :content_type, "application/octet-stream")
      url = s3_object_url(config, key)
      do_put(url, body, content_type, config)
    end
  end

  @impl true
  def delete(keys) when is_list(keys) do
    if keys == [] do
      :ok
    else
      case s3_config() do
        {:error, :not_configured} = err ->
          Logger.error("storage s3 delete failed: not configured", count: length(keys))
          err

        {:ok, config} ->
          do_delete_many(keys, config)
      end
    end
  end

  @impl true
  def url(key) when is_binary(key) do
    case cdn_base_url() do
      nil -> key
      "" -> key
      base -> String.trim_trailing(base, "/") <> "/" <> key
    end
  end

  # Private: PUT

  defp do_put(url, body, content_type, config) do
    payload_hash = sha256_hex(body)
    amz_date = amz_date()
    datestamp = binary_part(amz_date, 0, 8)
    headers = base_headers(url, payload_hash, amz_date, content_type)
    signed_headers = sign_request("PUT", url, headers, payload_hash, amz_date, datestamp, config)

    all_headers = Map.merge(headers, signed_headers)

    # Telemetry is added at the facade layer; here we just do the request.
    # Total latency budget: S3 PUT should complete within 15s; retry only transient.
    case Req.put(url,
           headers: all_headers,
           body: body,
           retry: :safe_transient,
           receive_timeout: 15_000,
           pool_timeout: 5_000
         ) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        Logger.info("storage s3 put ok", key: extract_key_from_url(url, config), status: status)
        {:ok, extract_key_from_s3_url(url, config)}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.error("storage s3 put failed",
          status: status,
          body: truncate_body(body),
          url: redact_url(url)
        )

        {:error, {:s3_error, status, body}}

      {:error, exception} ->
        Logger.error("storage s3 put exception", error: inspect(exception))
        {:error, exception}
    end
  end

  defp do_delete_many(keys, config) do
    # Chunk and delete individually for simplicity and idempotency.
    # S3 DeleteObjects would be more efficient but requires XML; individual
    # DELETEs are idempotent and easy to retry. Use Task.async_stream with
    # limited concurrency.
    chunk_size = 100

    keys
    |> Enum.chunk_every(chunk_size)
    |> Enum.reduce_while(:ok, fn chunk, :ok ->
      result =
        chunk
        |> Task.async_stream(
          fn key -> delete_single(key, config) end,
          max_concurrency: 10,
          timeout: 15_000,
          on_timeout: :kill_task
        )
        |> Enum.reduce(:ok, fn
          {:ok, :ok}, acc -> acc
          {:ok, {:error, :not_found}}, acc -> acc
          {:ok, {:error, reason}}, _acc -> {:error, reason}
          {:exit, reason}, _acc -> {:error, reason}
        end)

      case result do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp delete_single(key, config) do
    url = s3_object_url(config, key)
    payload_hash = sha256_hex("")
    amz_date = amz_date()
    datestamp = binary_part(amz_date, 0, 8)
    headers = base_headers(url, payload_hash, amz_date, nil)
    signed = sign_request("DELETE", url, headers, payload_hash, amz_date, datestamp, config)
    all_headers = Map.merge(headers, signed)

    case Req.delete(url,
           headers: all_headers,
           retry: :safe_transient,
           receive_timeout: 15_000,
           pool_timeout: 5_000
         ) do
      {:ok, %Req.Response{status: status}} when status in [200, 204, 404] ->
        :ok

      {:ok, %Req.Response{status: status, body: body}} ->
        # 404 / NoSuchKey is idempotent success, already handled; other
        # statuses are errors.
        Logger.error("storage s3 delete failed",
          key: key,
          status: status,
          body: truncate_body(body)
        )

        {:error, {:s3_error, status}}

      {:error, exception} ->
        Logger.error("storage s3 delete exception", key: key, error: inspect(exception))
        {:error, exception}
    end
  end

  defp base_headers(url, payload_hash, amz_date, content_type) do
    uri = URI.parse(url)
    host = uri.host

    headers = %{
      "host" => host,
      "x-amz-content-sha256" => payload_hash,
      "x-amz-date" => amz_date
    }

    if content_type do
      Map.put(headers, "content-type", content_type)
    else
      headers
    end
  end

  defp sign_request(method, url, headers, payload_hash, amz_date, datestamp, config) do
    %{access_key_id: access_key, secret_access_key: secret, region: region} = config
    uri = URI.parse(url)
    canonical_uri = encode_uri_path(uri.path || "/")
    canonical_querystring = uri.query || ""
    sorted_header_names = headers |> Map.keys() |> Enum.map(&String.downcase/1) |> Enum.sort()

    canonical_headers =
      Enum.map_join(sorted_header_names, "", fn name ->
        value = Map.get(headers, name) || Map.get(headers, String.downcase(name)) || ""
        "#{name}:#{String.trim(value)}\n"
      end)

    signed_headers = Enum.join(sorted_header_names, ";")

    canonical_request =
      [
        method,
        canonical_uri,
        canonical_querystring,
        canonical_headers,
        signed_headers,
        payload_hash
      ]
      |> Enum.join("\n")

    hashed_canonical = sha256_hex(canonical_request)
    credential_scope = "#{datestamp}/#{region}/s3/aws4_request"
    string_to_sign = "AWS4-HMAC-SHA256\n#{amz_date}\n#{credential_scope}\n#{hashed_canonical}"

    signing_key =
      ("AWS4" <> secret)
      |> hmac_sha256(datestamp)
      |> hmac_sha256(region)
      |> hmac_sha256("s3")
      |> hmac_sha256("aws4_request")

    signature = hmac_sha256(signing_key, string_to_sign) |> Base.encode16(case: :lower)

    authorization =
      "AWS4-HMAC-SHA256 Credential=#{access_key}/#{credential_scope}, SignedHeaders=#{signed_headers}, Signature=#{signature}"

    %{"authorization" => authorization}
  end

  # Helpers: config

  defp s3_config do
    load_s3_config() |> validate_s3_config()
  end

  defp load_s3_config do
    conf = Application.get_env(:crysa, Crysa.Storage, [])

    %{
      bucket: Keyword.get(conf, :bucket) || System.get_env("R2_BUCKET_NAME"),
      account_id: Keyword.get(conf, :account_id) || System.get_env("R2_ACCOUNT_ID"),
      access_key_id: Keyword.get(conf, :access_key_id) || System.get_env("R2_ACCESS_KEY_ID"),
      secret_access_key:
        Keyword.get(conf, :secret_access_key) || System.get_env("R2_SECRET_ACCESS_KEY"),
      cdn_base: Keyword.get(conf, :cdn_base_url) || System.get_env("R2_DOMAIN_CDN_URL"),
      endpoint_url:
        Keyword.get(conf, :endpoint_url) ||
          endpoint_from_account(Keyword.get(conf, :account_id) || System.get_env("R2_ACCOUNT_ID")),
      region: Keyword.get(conf, :region, "auto")
    }
  end

  defp validate_s3_config(
         %{bucket: bucket, access_key_id: ak, secret_access_key: sk, endpoint_url: endpoint} = cfg
       ) do
    cond do
      blank?(bucket) -> {:error, :not_configured}
      blank?(ak) -> {:error, :not_configured}
      blank?(sk) -> {:error, :not_configured}
      blank?(endpoint) -> {:error, :not_configured}
      true -> {:ok, format_s3_config(cfg)}
    end
  end

  defp format_s3_config(%{
         bucket: bucket,
         account_id: account_id,
         access_key_id: ak,
         secret_access_key: sk,
         cdn_base: cdn_base,
         endpoint_url: endpoint,
         region: region
       }) do
    %{
      bucket: bucket,
      account_id: account_id,
      access_key_id: ak,
      secret_access_key: sk,
      endpoint_url: String.trim_trailing(endpoint, "/"),
      cdn_base_url: cdn_base && String.trim_trailing(cdn_base, "/"),
      region: region
    }
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  defp endpoint_from_account(nil), do: nil
  defp endpoint_from_account(""), do: nil
  defp endpoint_from_account(account_id), do: "https://#{account_id}.r2.cloudflarestorage.com"

  defp cdn_base_url do
    conf = Application.get_env(:crysa, Crysa.Storage, [])
    Keyword.get(conf, :cdn_base_url) || System.get_env("R2_DOMAIN_CDN_URL")
  end

  defp s3_object_url(%{endpoint_url: endpoint, bucket: bucket}, key) do
    # Path-style: https://<endpoint>/<bucket>/<key>
    "#{String.trim_trailing(endpoint, "/")}/#{bucket}/#{key}"
  end

  defp extract_key_from_url(url, %{endpoint_url: endpoint, bucket: bucket}) do
    prefix = "#{String.trim_trailing(endpoint, "/")}/#{bucket}/"

    case String.split(url, prefix, parts: 2) do
      [_, key] -> key
      _ -> url
    end
  end

  defp extract_key_from_s3_url(url, config), do: extract_key_from_url(url, config)

  defp read_body({:file, path}) when is_binary(path), do: File.read(path)

  defp read_body(binary) when is_binary(binary), do: {:ok, binary}
  defp read_body(_), do: {:error, :invalid_data}

  defp validate_key_s3(key) do
    cond do
      not is_binary(key) -> {:error, :invalid_key}
      byte_size(key) == 0 or byte_size(key) > 1_024 -> {:error, :invalid_key}
      String.starts_with?(key, "/") -> {:error, :invalid_key}
      String.contains?(key, ["..", "\\", "//"]) -> {:error, :invalid_key}
      not Regex.match?(~r/\A[a-zA-Z0-9_\-\/\.]+\z/, key) -> {:error, :invalid_key}
      true -> :ok
    end
  end

  defp sha256_hex(data) when is_binary(data) do
    :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
  end

  defp hmac_sha256(key, data) when is_binary(key) and is_binary(data) do
    :crypto.mac(:hmac, :sha256, key, data)
  end

  defp amz_date do
    DateTime.utc_now()
    |> Calendar.strftime("%Y%m%dT%H%M%SZ")
  end

  defp encode_uri_path(path) do
    path
    |> String.split("/")
    |> Enum.map_join("/", fn segment -> URI.encode(segment, &URI.char_unreserved?/1) end)
  end

  defp truncate_body(body) when is_binary(body),
    do: binary_part(body, 0, min(byte_size(body), 500))

  defp truncate_body(body), do: inspect(body) |> binary_part(0, 500)

  defp redact_url(url) when is_binary(url) do
    # Never log full presigned URLs; just host + path prefix.
    case URI.parse(url) do
      %URI{host: host, path: path} when is_binary(host) ->
        "#{host}#{String.slice(path || "", 0, 60)}"

      _ ->
        "redacted"
    end
  end
end
