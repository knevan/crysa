defmodule Crysa.Storage.Local do
  @moduledoc """
  Local filesystem adapter for `Crysa.Storage`.

  Stores objects under a configurable `storage_root` directory (default
  `priv/static/uploads`) and exposes them via a configurable `url_prefix`
  (default `"/uploads"`). In production this adapter is typically replaced
  by `Crysa.Storage.S3`, but it is fully functional for development, test
  and for environments without an S3-compatible bucket.

  The adapter validates keys with the same rules as the facade and ensures
  the resolved absolute path never escapes `storage_root` (defence against
  directory traversal even if a caller bypasses facade validation).
  """

  @behaviour Crysa.Storage.Adapter

  require Logger

  @impl true
  def put(key, data, _opts) when is_binary(key) do
    with :ok <- validate_key_local(key),
         {:ok, full_path} <- full_path(key),
         :ok <- ensure_parent_dir(full_path) do
      result =
        case data do
          {:file, src_path} when is_binary(src_path) ->
            copy_file(src_path, full_path)

          binary when is_binary(binary) ->
            File.write(full_path, binary)
        end

      case result do
        :ok -> {:ok, key}
        {:ok, _} -> {:ok, key}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl true
  def delete(keys) when is_list(keys) do
    Enum.reduce(keys, :ok, fn key, acc ->
      case delete_single(key) do
        :ok -> acc
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @impl true
  def url(key) when is_binary(key) do
    prefix = url_prefix()
    # Ensure single slash between prefix and key
    prefix = String.trim_trailing(prefix, "/")
    "#{prefix}/#{key}"
  end

  # Private

  defp delete_single(key) when is_binary(key) do
    with :ok <- validate_key_local(key),
         {:ok, full_path} <- full_path(key) do
      case File.rm(full_path) do
        :ok ->
          :ok

        {:error, :enoent} ->
          :ok

        {:error, reason} ->
          Logger.warning("storage local delete failed",
            key: key,
            reason: inspect(reason)
          )

          {:error, reason}
      end
    else
      {:error, _reason} = err ->
        # Invalid keys are treated as non-deletable but logged.
        Logger.warning("storage local delete skipped invalid key", key: key, error: inspect(err))
        :ok
    end
  end

  defp copy_file(src, dest), do: File.cp(src, dest)

  defp ensure_parent_dir(path), do: path |> Path.dirname() |> File.mkdir_p()

  defp full_path(key) do
    root = storage_root()
    # Join and expand to prevent traversal.
    joined = Path.join(root, key)
    expanded_root = Path.expand(root)
    expanded_joined = Path.expand(joined)

    if String.starts_with?(expanded_joined, expanded_root <> "/") or
         expanded_joined == expanded_root do
      {:ok, expanded_joined}
    else
      {:error, :invalid_key}
    end
  end

  defp validate_key_local(key) do
    cond do
      not is_binary(key) -> {:error, :invalid_key}
      byte_size(key) == 0 or byte_size(key) > 1_024 -> {:error, :invalid_key}
      String.starts_with?(key, "/") -> {:error, :invalid_key}
      String.contains?(key, ["..", "\\", "//"]) -> {:error, :invalid_key}
      not Regex.match?(~r/\A[a-zA-Z0-9_\-\/\.]+\z/, key) -> {:error, :invalid_key}
      true -> :ok
    end
  end

  defp storage_root do
    config = Application.get_env(:crysa, Crysa.Storage, [])
    Keyword.get(config, :storage_root, default_root())
  end

  defp url_prefix do
    config = Application.get_env(:crysa, Crysa.Storage, [])
    Keyword.get(config, :url_prefix, "/uploads")
  end

  # credo:disable-for-next-line
  defp default_root do
    # priv/static/uploads relative to the crysa app
    try do
      Application.app_dir(:crysa, "priv/static/uploads")
    rescue
      _ -> Path.join(File.cwd!(), "priv/static/uploads")
    end
  end
end
