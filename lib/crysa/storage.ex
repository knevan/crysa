defmodule Crysa.Storage do
  @moduledoc """
  Object storage abstraction for CrysA.

  Mirrors the intent of Castra's `StorageClient` (`backend/src/database/storage.rs`)
  but adapts it to idiomatic Elixir/OTP:

  - A pluggable adapter behaviour (`Crysa.Storage.Adapter`) with a `Local`
    filesystem backend for development/test and an `S3` (R2-compatible)
    backend for production.
  - Strict storage-key validation (relative, no traversal, allowlisted
    charset, max 1024 chars) on both the facade and each adapter.
  - Safe object-key extraction from trusted CDN URLs only. Untrusted URLs
    are rejected with `{:error, :untrusted_url}` and are never deleted.
  - High-level upload helpers for the four object families required by the
    plan: cover images, avatars, chapter images and comment attachments.
  - Idempotent, chunked deletion so bulk operations (e.g. series deletion)
    can be retried without leaking partial state. The facade never holds a
    database transaction while touching object storage.

  ## Configuration

      config :crysa, Crysa.Storage,
        adapter: Crysa.Storage.Local,  # or Crysa.Storage.S3
        storage_root: "priv/static/uploads",
        url_prefix: "/uploads",
        cdn_base_url: "https://cdn.example.com",
        trusted_cdn_urls: ["https://cdn.example.com", "https://pub-xxx.r2.dev"],
        # S3 / R2 only:
        bucket: "my-bucket",
        account_id: "...",
        access_key_id: "...",
        secret_access_key: "...",
        endpoint_url: "https://<account>.r2.cloudflarestorage.com",
        region: "auto"

  `trusted_cdn_urls` defaults to `[cdn_base_url]` when set. For the local
  adapter the `url_prefix` (e.g. `"/uploads"`) is automatically trusted for
  relative URLs.
  """

  require Logger

  @type key :: String.t()
  @type url :: String.t()
  @type store_result :: {:ok, %{key: key(), url: url()}} | {:error, term()}

  @max_key_length 1_024
  @key_regex ~r/\A[a-zA-Z0-9_\-\/\.]+\z/
  @max_avatar_bytes 2 * 1024 * 1024
  @max_cover_bytes 5 * 1024 * 1024
  @max_attachment_bytes 5 * 1024 * 1024
  @max_chapter_image_bytes 10 * 1024 * 1024
  @allowed_image_types ~w(image/jpeg image/png image/webp image/gif image/jpg)
  @delete_chunk_size 500

  @doc """
  Stores raw bytes or a file at `key`.

  `data` may be a binary or `{:file, path}`. `:content_type` is required
  for S3 backends and validated for all backends. Keys are strictly
  validated before delegating to the adapter.

  Emits telemetry `[:crysa, :storage, :put]` with `:start`/`:stop`/`:exception`.
  """
  @spec put(key(), binary() | {:file, Path.t()}, keyword()) :: {:ok, key()} | {:error, term()}
  def put(key, data, opts \\ []) when is_binary(key) do
    with :ok <- validate_key(key) do
      adapter = adapter()
      meta = %{key: key, adapter: adapter, content_type: Keyword.get(opts, :content_type)}
      start = System.monotonic_time()

      :telemetry.execute(
        [:crysa, :storage, :put, :start],
        %{system_time: System.system_time()},
        meta
      )

      result = adapter.put(key, data, opts)

      duration = System.monotonic_time() - start

      case result do
        {:ok, _} = ok ->
          :telemetry.execute(
            [:crysa, :storage, :put, :stop],
            %{duration: duration},
            Map.put(meta, :result, :ok)
          )

          ok

        {:error, reason} = err ->
          :telemetry.execute(
            [:crysa, :storage, :put, :exception],
            %{duration: duration},
            Map.merge(meta, %{reason: reason, kind: :error})
          )

          err
      end
    end
  end

  @doc "Returns the public URL for `key` via the configured adapter."
  @spec url_for(key()) :: url()
  def url_for(key) when is_binary(key) do
    case validate_key(key) do
      :ok -> adapter().url(key)
      {:error, _} -> adapter().url(key)
    end
  end

  @doc """
  Extracts a storage key from a trusted CDN URL.

  Only URLs whose host/prefix matches `trusted_cdn_urls` (or the relative
  `url_prefix` for local storage) are accepted. Returns
  `{:error, :untrusted_url}` for foreign hosts, `{:error, :invalid_url}`
  for malformed URLs and `{:error, :invalid_key}` when the extracted key
  fails validation.

  The function is the Elixir counterpart of Castra's
  `StorageClient::extract_object_key_from_url`.
  """
  @spec key_from_url(url()) :: {:ok, key()} | {:error, term()}
  def key_from_url(url) when is_binary(url) do
    url = String.trim(url)

    cond do
      url == "" ->
        {:error, :invalid_url}

      String.starts_with?(url, "/") ->
        extract_from_relative(url)

      true ->
        extract_from_absolute(url)
    end
  end

  def key_from_url(_), do: {:error, :invalid_url}

  @doc """
  Extracts keys from a list of URLs, skipping untrusted/invalid entries.

  Returns the list of successfully extracted keys. Logs at `warning` level
  for each skipped URL (host only, not full URL).
  """
  @spec keys_from_urls([url()]) :: [key()]
  def keys_from_urls(urls) when is_list(urls) do
    Enum.flat_map(urls, fn url ->
      case key_from_url(url) do
        {:ok, key} ->
          [key]

        {:error, :untrusted_url} ->
          Logger.warning("storage key extraction skipped untrusted url", host: host_of(url))
          []

        {:error, reason} ->
          Logger.warning("storage key extraction skipped invalid url",
            reason: inspect(reason),
            host: host_of(url)
          )

          []
      end
    end)
  end

  @doc """
  Idempotent, chunked deletion of keys.

  Keys are validated, chunked into batches of #{@delete_chunk_size} and
  delegated to the adapter. Missing keys (`:enoent`/`NoSuchKey`) are treated
  as success. Emits `[:crysa, :storage, :delete]` telemetry.
  """
  @spec delete_many([key()]) :: :ok | {:error, term()}
  def delete_many(keys) when is_list(keys) do
    {valid_keys, invalid_keys} = Enum.split_with(keys, &valid_key?/1)

    if invalid_keys != [] do
      Logger.warning("storage delete skipped invalid keys",
        count: length(invalid_keys),
        sample: invalid_keys |> Enum.take(3) |> Enum.map(&String.slice(&1, 0, 80))
      )

      :telemetry.execute(
        [:crysa, :storage, :delete, :invalid_key],
        %{count: length(invalid_keys)},
        %{sample: invalid_keys |> Enum.take(3) |> Enum.map(&String.slice(&1, 0, 80))}
      )
    end

    if valid_keys == [] do
      :ok
    else
      do_delete_many(valid_keys)
    end
  end

  defp do_delete_many(valid_keys) do
    adapter = adapter()
    meta = %{count: length(valid_keys), adapter: adapter}
    start = System.monotonic_time()

    :telemetry.execute(
      [:crysa, :storage, :delete, :start],
      %{system_time: System.system_time()},
      meta
    )

    result = delete_chunks(valid_keys, adapter)
    duration = System.monotonic_time() - start
    emit_delete_result(result, duration, meta)
  end

  defp delete_chunks(keys, adapter) do
    keys
    |> Enum.chunk_every(delete_chunk_size())
    |> Enum.reduce_while(:ok, fn chunk, :ok ->
      case adapter.delete(chunk) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp emit_delete_result(:ok, duration, meta) do
    :telemetry.execute([:crysa, :storage, :delete, :stop], %{duration: duration}, meta)
    :ok
  end

  defp emit_delete_result({:error, reason} = err, duration, meta) do
    :telemetry.execute(
      [:crysa, :storage, :delete, :exception],
      %{duration: duration},
      Map.merge(meta, %{reason: reason})
    )

    err
  end

  @doc "Deletes a single key (idempotent)."
  @spec delete(key() | [key()]) :: :ok | {:error, term()}
  def delete(key) when is_binary(key), do: delete_many([key])
  def delete(keys) when is_list(keys), do: delete_many(keys)

  @doc """
  Deletes objects by their public URLs. Only trusted URLs are deleted;
  untrusted URLs are ignored and logged.
  """
  @spec delete_by_urls([url()]) :: :ok | {:error, term()}
  def delete_by_urls(urls) when is_list(urls) do
    urls |> keys_from_urls() |> delete_many()
  end

  # High-level upload helpers

  @doc """
  Stores an avatar upload for `user`.

  Validates content type (`image/jpeg`, `image/png`, `image/webp`,
  `image/gif`), file size (max 2 MiB) and generates an unguessable key
  `avatars/user_<id>_<uuid>.<ext>` (or `avatars/<uuid>.<ext>` when no user
  is given). Returns `{:ok, %{key, url}}`.
  """
  @spec store_avatar(Plug.Upload.t(), map() | integer() | nil) :: store_result()
  def store_avatar(%Plug.Upload{} = upload, user_or_id \\ nil) do
    with {:ok, ext} <- validate_content_type(upload.content_type, :avatar),
         :ok <- validate_extension(upload.filename, ext),
         :ok <-
           validate_upload_file(
             upload.path,
             @max_avatar_bytes,
             "The avatar must be 2 MB or smaller."
           ),
         {:ok, key} <- avatar_key(upload, ext, user_or_id),
         {:ok, _} <- put(key, {:file, upload.path}, content_type: upload.content_type) do
      {:ok, %{key: key, url: url_for(key)}}
    end
  end

  @doc """
  Stores a series cover upload.

  Validates type and size (max 5 MiB), generates `covers/<uuid>.<ext>` and
  stores via the adapter.
  """
  @spec store_cover(Plug.Upload.t()) :: store_result()
  def store_cover(%Plug.Upload{} = upload) do
    with {:ok, ext} <- validate_content_type(upload.content_type, :cover),
         :ok <- validate_extension(upload.filename, ext),
         :ok <-
           validate_upload_file(
             upload.path,
             @max_cover_bytes,
             "The cover must be 5 MB or smaller."
           ),
         {:ok, key} <- cover_key(ext),
         {:ok, _} <- put(key, {:file, upload.path}, content_type: upload.content_type) do
      {:ok, %{key: key, url: url_for(key)}}
    end
  end

  @doc """
  Stores a comment attachment upload for `user_id`.

  Validates type and size (max 5 MiB), generates
  `comments/<user_id>/<uuid>.<ext>`.
  """
  @spec store_comment_attachment(Plug.Upload.t(), integer()) :: store_result()
  def store_comment_attachment(%Plug.Upload{} = upload, user_id) when is_integer(user_id) do
    with {:ok, ext} <- validate_content_type(upload.content_type, :attachment),
         :ok <- validate_extension(upload.filename, ext),
         :ok <-
           validate_upload_file(
             upload.path,
             @max_attachment_bytes,
             "The attachment must be 5 MB or smaller."
           ),
         {:ok, key} <- attachment_key(ext, user_id),
         {:ok, _} <- put(key, {:file, upload.path}, content_type: upload.content_type) do
      {:ok, %{key: key, url: url_for(key)}}
    end
  end

  @doc """
  Stores a chapter image (already validated/converted, typically `image/webp`).

  Accepts `data` as binary or `{:file, path}` and stores at
  `chapters/<series_id>/<chapter_key>/<order>.webp` or a random key when
  no series/chapter context is provided. Validates size (max 10 MiB) and
  content type.
  """
  @spec store_chapter_image(binary() | {:file, Path.t()}, keyword()) :: store_result()
  def store_chapter_image(data, opts \\ []) when is_list(opts) do
    content_type = Keyword.get(opts, :content_type, "image/webp")
    series_id = Keyword.get(opts, :series_id)
    chapter_key = Keyword.get(opts, :chapter_key)
    image_order = Keyword.get(opts, :image_order)

    with {:ok, ext} <- validate_content_type(content_type, :chapter_image),
         :ok <- validate_chapter_image_size(data),
         {:ok, key} <- chapter_image_key(ext, series_id, chapter_key, image_order),
         {:ok, _} <- put(key, data, content_type: content_type) do
      {:ok, %{key: key, url: url_for(key)}}
    end
  end

  @doc """
  Stores multiple chapter images sequentially (e.g. from a download worker).

  Each entry must be `%{data: binary() | {:file, path}, content_type: String.t(), order: integer()}`.
  Returns `{:ok, [%{key, url}]}` or `{:error, reason}` on first failure.

  On partial failure the already stored images are deleted best-effort to
  avoid orphans; callers that need stronger guarantees should run a
  reconciliation job or handle cleanup externally. The operation is not
  atomic across storage and DB — DB inserts should happen after this
  succeeds.
  """
  @spec store_chapter_images([map()], keyword()) ::
          {:ok, [%{key: key(), url: url()}]} | {:error, term()}
  def store_chapter_images(entries, opts \\ []) when is_list(entries) do
    result =
      Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
        entry_map = Map.new(entry, fn {k, v} -> {to_string(k), v} end)
        data = Map.get(entry_map, "data")
        content_type = Map.get(entry_map, "content_type", "image/webp")
        order = Map.get(entry_map, "order") || Map.get(entry_map, "image_order") || 0

        case store_chapter_image(
               data,
               Keyword.merge(opts, content_type: content_type, image_order: order)
             ) do
          {:ok, result} -> {:cont, {:ok, [result | acc]}}
          {:error, reason} -> {:halt, {:error, reason, acc}}
        end
      end)

    case result do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, reason, acc} -> handle_chapter_images_partial_failure(acc, reason)
      {:error, reason} -> {:error, reason}
    end
  end

  defp handle_chapter_images_partial_failure(acc, reason) do
    keys = Enum.map(acc, & &1.key)

    case delete_many(keys) do
      :ok ->
        Logger.warning("storage chapter images partial failure cleaned up", count: length(keys))

      {:error, del_reason} ->
        Logger.error("storage chapter images cleanup failed",
          reason: inspect(del_reason),
          count: length(keys)
        )
    end

    {:error, reason}
  end

  # Validation

  @doc "Validates a storage key strictly (public, used by tests)."
  @spec validate_key(key()) :: :ok | {:error, term()}
  def validate_key(key) when is_binary(key) do
    cond do
      byte_size(key) == 0 -> {:error, :invalid_key}
      byte_size(key) > @max_key_length -> {:error, :invalid_key}
      String.starts_with?(key, "/") -> {:error, :invalid_key}
      String.contains?(key, "..") -> {:error, :invalid_key}
      String.contains?(key, "\\") -> {:error, :invalid_key}
      String.contains?(key, "//") -> {:error, :invalid_key}
      not Regex.match?(@key_regex, key) -> {:error, :invalid_key}
      true -> :ok
    end
  end

  def validate_key(_), do: {:error, :invalid_key}

  @spec valid_key?(key()) :: boolean()
  def valid_key?(key), do: validate_key(key) == :ok

  # Private: content type

  # Phase 10 follow-up: Add MIME sniffing (magic bytes) and re-encoding via Vix/Image
  # to prevent spoofed content-type payloads. Currently validates header only.
  defp validate_content_type(content_type, _kind)
       when content_type in @allowed_image_types do
    {:ok, extension_for(content_type)}
  end

  defp validate_content_type(_content_type, _kind) do
    {:error, "Only JPEG, PNG, WebP, and GIF images are allowed."}
  end

  defp validate_extension(filename, expected_ext) when is_binary(filename) do
    ext = filename |> Path.extname() |> String.downcase()

    cond do
      ext == "" -> :ok
      ext == expected_ext -> :ok
      expected_ext == ".jpg" and ext in [".jpg", ".jpeg"] -> :ok
      true -> {:error, "Only JPEG, PNG, WebP, and GIF images are allowed."}
    end
  end

  defp validate_extension(_, _), do: :ok

  defp extension_for("image/jpeg"), do: ".jpg"
  defp extension_for("image/jpg"), do: ".jpg"
  defp extension_for("image/png"), do: ".png"
  defp extension_for("image/webp"), do: ".webp"
  defp extension_for("image/gif"), do: ".gif"
  # Unreachable — validate_content_type rejects unknown types before this is called
  defp extension_for(_), do: ".jpg"

  defp validate_file_size(path, max, message) when is_binary(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} when size <= max -> :ok
      {:ok, %File.Stat{size: _}} -> {:error, message}
      {:error, _} -> {:error, "Could not read the uploaded file."}
    end
  end

  defp validate_upload_file(path, max, message) when is_binary(path),
    do: validate_file_size(path, max, message)

  defp validate_chapter_image_size(data) when is_binary(data) do
    if byte_size(data) <= @max_chapter_image_bytes,
      do: :ok,
      else: {:error, "Chapter image must be 10 MB or smaller."}
  end

  defp validate_chapter_image_size({:file, path}) when is_binary(path) do
    validate_file_size(path, @max_chapter_image_bytes, "Chapter image must be 10 MB or smaller.")
  end

  defp validate_chapter_image_size(_), do: {:error, "Invalid image data."}

  # Key generation

  defp avatar_key(_upload, ext, user_or_id) do
    uuid = random_id()

    key =
      case extract_user_id(user_or_id) do
        nil -> "avatars/#{uuid}#{ext}"
        id when is_integer(id) -> "avatars/user_#{id}_#{uuid}#{ext}"
      end

    {:ok, key}
  end

  defp cover_key(ext) do
    uuid = random_id()
    {:ok, "covers/#{uuid}#{ext}"}
  end

  defp attachment_key(ext, user_id) when is_integer(user_id) do
    uuid = random_id()
    {:ok, "comments/#{user_id}/#{uuid}#{ext}"}
  end

  defp chapter_image_key(ext, series_id, chapter_key, image_order) do
    cond do
      is_integer(series_id) and is_binary(chapter_key) and is_integer(image_order) ->
        # Sanitize chapter_key for path use: replace unsafe chars with "_"
        safe_ck = sanitize_path_segment(chapter_key)
        {:ok, "chapters/#{series_id}/#{safe_ck}/#{pad_order(image_order)}#{ext}"}

      is_integer(series_id) and is_integer(image_order) ->
        {:ok, "chapters/#{series_id}/#{random_id()}#{ext}"}

      is_integer(image_order) ->
        {:ok, "chapters/#{random_id()}/#{pad_order(image_order)}#{ext}"}

      true ->
        {:ok, "chapters/#{random_id()}#{ext}"}
    end
  end

  defp sanitize_path_segment(segment) when is_binary(segment) do
    sanitized =
      segment
      |> String.replace("..", "_")
      |> String.replace(~r/[^a-zA-Z0-9_\-\.]/, "_")
      |> String.replace("..", "_")
      |> String.trim("_")
      |> truncate(64)

    if sanitized == "", do: "chapter", else: sanitized
  end

  defp truncate(str, max) when byte_size(str) > max, do: binary_part(str, 0, max)
  defp truncate(str, _max), do: str

  defp pad_order(order) when is_integer(order), do: String.pad_leading("#{order}", 4, "0")

  defp random_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end

  defp extract_user_id(nil), do: nil
  defp extract_user_id(id) when is_integer(id), do: id
  defp extract_user_id(%{id: id}) when is_integer(id), do: id
  defp extract_user_id(%{"id" => id}) when is_integer(id), do: id
  defp extract_user_id(_), do: nil

  # URL extraction

  defp extract_from_relative(url) do
    prefix = url_prefix() |> String.trim_trailing("/")

    cond do
      url == prefix ->
        {:error, :invalid_key}

      String.starts_with?(url, prefix <> "/") ->
        key =
          url
          |> String.replace_prefix(prefix, "")
          |> String.trim_leading("/")
          |> strip_query()

        key = URI.decode(key)
        validate_and_return_key(key, url)

      true ->
        {:error, :untrusted_url}
    end
  end

  defp extract_from_absolute(url) do
    uri = URI.parse(url)

    cond do
      is_nil(uri.host) -> {:error, :invalid_url}
      uri.scheme not in ["http", "https"] -> {:error, :untrusted_url}
      true -> extract_via_trusted_bases(uri, url)
    end
  end

  defp extract_via_trusted_bases(uri, url) do
    trusted = trusted_cdn_urls()

    case Enum.find_value(trusted, fn base -> match_trusted_base(uri, base) end) do
      nil -> {:error, :untrusted_url}
      key -> validate_and_return_key(key, url)
    end
  end

  defp match_trusted_base(target_uri, base_url) when is_binary(base_url) do
    base_uri = URI.parse(base_url)

    if trusted_host_mismatch?(base_uri, target_uri),
      do: nil,
      else: extract_key_from_trusted_paths(base_uri, target_uri)
  end

  defp trusted_host_mismatch?(base_uri, target_uri) do
    is_nil(base_uri.host) or
      String.downcase(base_uri.host) != String.downcase(target_uri.host || "") or
      normalize_scheme(base_uri.scheme) != normalize_scheme(target_uri.scheme) or
      (base_uri.port != target_uri.port and not is_nil(base_uri.port))
  end

  defp extract_key_from_trusted_paths(base_uri, target_uri) do
    base_path = String.trim_trailing(base_uri.path || "", "/")
    target_path = String.trim_leading(target_uri.path || "", "/")

    cond do
      base_path == "" or base_path == "/" ->
        if target_path == "", do: nil, else: URI.decode(target_path) |> strip_query()

      path_matches_base?(target_path, base_path) ->
        extract_after_base(target_path, base_path)

      true ->
        nil
    end
  end

  defp path_matches_base?(target_path, base_path) do
    base_trimmed = String.trim_leading(base_path, "/")

    target_path == base_trimmed or String.starts_with?("/" <> target_path, base_path <> "/")
  end

  defp extract_after_base(target_path, base_path) do
    base_trimmed = String.trim_leading(base_path, "/")
    key = String.slice(target_path, String.length(base_trimmed)..-1//1)
    key = key |> String.trim_leading("/") |> URI.decode() |> strip_query()
    if key == "", do: nil, else: key
  end

  defp normalize_scheme(nil), do: nil
  defp normalize_scheme(s), do: String.downcase(s)

  defp strip_query(key) when is_binary(key) do
    case String.split(key, "?", parts: 2) do
      [k | _] -> k
      _ -> key
    end
  end

  defp validate_and_return_key(key, _url) when is_binary(key) do
    # Remove fragment
    key = key |> String.split("#", parts: 2) |> hd() |> String.trim()

    case validate_key(key) do
      :ok -> {:ok, key}
      {:error, _} = err -> err
    end
  end

  defp trusted_cdn_urls do
    config = Application.get_env(:crysa, Crysa.Storage, [])
    cdn = Keyword.get(config, :cdn_base_url)
    trusted = Keyword.get(config, :trusted_cdn_urls)

    cond do
      is_list(trusted) and trusted != [] -> trusted
      is_binary(cdn) and cdn != "" -> [cdn]
      true -> []
    end
  end

  defp url_prefix do
    config = Application.get_env(:crysa, Crysa.Storage, [])
    Keyword.get(config, :url_prefix, "/uploads")
  end

  defp adapter do
    config = Application.get_env(:crysa, Crysa.Storage, [])

    if Keyword.has_key?(config, :adapter) do
      Keyword.get(config, :adapter)
    else
      case Application.get_env(:crysa, :storage) do
        list when is_list(list) -> Keyword.get(list, :adapter, Crysa.Storage.Local)
        _ -> Crysa.Storage.Local
      end
    end
  end

  defp delete_chunk_size do
    config = Application.get_env(:crysa, Crysa.Storage, [])
    Keyword.get(config, :delete_chunk_size, @delete_chunk_size)
  end

  defp host_of(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) -> host
      _ -> "unknown"
    end
  end
end
