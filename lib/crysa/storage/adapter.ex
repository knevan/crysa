defmodule Crysa.Storage.Adapter do
  @moduledoc """
  Behaviour for object-storage backends.

  Implementations must provide `put/3`, `delete/2` and `url/1`. The facade
  `Crysa.Storage` adds validation, telemetry, safe URL extraction and
  chunked deletion on top of these primitives.

  All keys are relative POSIX-style paths (e.g. `avatars/abc.webp`) without
  a leading slash, without `..`, without backslashes and using only
  `[a-zA-Z0-9_\\-\\/\\.]` (max 1024 chars). Adapters must not accept
  absolute keys.
  """

  @type key :: String.t()
  @type url :: String.t()
  @type content_type :: String.t()

  @doc """
  Stores `data` at `key`.

  `data` is either a binary or `{:file, path}`. `opts` must contain at
  least `:content_type`. Returns `{:ok, key}` on success.
  """
  @callback put(key(), binary() | {:file, Path.t()}, keyword()) ::
              {:ok, key()} | {:error, term()}

  @doc """
  Deletes the given keys. Must be idempotent: deleting a non-existent key
  is `:ok`. Implementations should treat `NoSuchKey`/`:enoent` as success.
  """
  @callback delete([key()]) :: :ok | {:error, term()}

  @doc "Returns the public URL for `key`."
  @callback url(key()) :: url()
end
