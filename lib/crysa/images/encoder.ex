defmodule Crysa.Images.Encoder do
  @moduledoc """
  Behaviour for image encoding (JPEG/PNG → WebP) used by the chapter
  download pipeline.

  All pixel-level work must stay inside the native encoder implementation;
  compressed bytes in, compressed WebP out. Implementations are expected to
  enforce their own dimension/megapixel limits on top of the byte-size
  checks performed by `Crysa.Images.Limits`.

  The production implementation is `Crysa.Images.Encoder.Vix` (libvips via
  the precompiled NIF; no system libvips needed on supported platforms).
  Encoders run on dirty CPU schedulers.
  """

  @type source :: binary() | {:file, Path.t()}

  @callback to_webp(source(), keyword()) :: {:ok, binary()} | {:error, term()}

  @doc "Resolves the configured encoder adapter."
  @spec adapter() :: module()
  def adapter do
    :crysa
    |> Application.get_env(Crysa.Images, [])
    |> Keyword.get(:encoder, Crysa.Images.Encoder.Vix)
  end

  @doc "Encodes `source` to WebP via the configured adapter."
  @spec to_webp(source(), keyword()) :: {:ok, binary()} | {:error, term()}
  def to_webp(source, opts \\ []) do
    adapter().to_webp(source, opts)
  end
end
