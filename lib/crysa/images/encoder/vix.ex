defmodule Crysa.Images.Encoder.Vix do
  @moduledoc """
  WebP encoder backed by libvips via `Vix`.

  Uses Vix's precompiled NIF + bundled libvips (the default compilation
  mode), so no system libvips is required on supported platforms. All
  pixel-level work stays inside libvips; this adapter only orchestrates:

    1. Byte-size guard (`Crysa.Images.Limits.validate_input/2`) before decode.
    2. Decode from binary or file.
    3. Dimension guard (`validate_dimensions/3`) after decode, before encode.
    4. Encode to WebP (lossy, quality/effort bounded, metadata stripped).

  The caller (`Crysa.Processing.ChapterDownload`) additionally wraps the
  whole call in an encode timeout — libvips NIFs run on dirty CPU schedulers,
  so a slow encode blocks only that job's scheduler slot, not the VM.
  """

  @behaviour Crysa.Images.Encoder

  alias Crysa.Images.Limits

  @impl true
  def to_webp(source, opts) do
    limits = Keyword.get(opts, :limits, Limits.defaults())
    quality = Keyword.get(opts, :quality, 80)
    effort = Keyword.get(opts, :effort, 4)

    with :ok <- Limits.validate_input(source, limits),
         {:ok, image} <- open(source),
         :ok <- validate_dimensions(image, limits),
         {:ok, webp} <- encode(image, quality, effort) do
      {:ok, webp}
    else
      {:error, reason} = _error when is_atom(reason) or is_binary(reason) ->
        {:error, reason}

      {:error, other} ->
        {:error, inspect(other)}
    end
  rescue
    # Vix NIF failures surface as ErlangError wrapping the libvips message.
    e in [RuntimeError, ArgumentError, ErlangError] -> {:error, Exception.message(e)}
  catch
    kind, value -> {:error, "vix encode #{kind}: " <> inspect(value)}
  end

  defp open({:file, path}) when is_binary(path), do: Vix.Vips.Image.new_from_file(path)

  defp open(binary) when is_binary(binary), do: Vix.Vips.Image.new_from_buffer(binary)

  defp validate_dimensions(image, limits) do
    width = Vix.Vips.Image.width(image)
    height = Vix.Vips.Image.height(image)
    Limits.validate_dimensions(width, height, limits)
  end

  defp encode(image, quality, effort) do
    # strip: true drops metadata (EXIF/GPS/ICC) — chapter pages carry none.
    Vix.Vips.Image.write_to_buffer(image, ".webp", Q: quality, effort: effort, strip: true)
  end
end
