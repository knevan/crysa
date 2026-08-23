defmodule Crysa.Images.Encoder.VixTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Crysa.Images.Encoder
  alias Crysa.Images.Limits

  # Fixtures are generated with libvips itself; the round trip proves the NIF
  # loads and that decode → WebP encode works end to end.
  defp png_fixture do
    {:ok, img} = Vix.Vips.Operation.black(16, 16)
    {:ok, png} = Vix.Vips.Image.write_to_buffer(img, ".png")
    png
  end

  describe "to_webp/2" do
    test "encodes binary input to WebP" do
      assert {:ok, webp} = Encoder.to_webp(png_fixture())
      assert byte_size(webp) > 0
      assert <<"RIFF", _::binary>> = webp
    end

    test "encodes file input" do
      path = Path.join(System.tmp_dir!(), "crysa-vix-#{System.unique_integer()}.png")
      File.write!(path, png_fixture())
      on_exit(fn -> File.rm(path) end)

      assert {:ok, webp} = Encoder.to_webp({:file, path})
      assert <<"RIFF", _::binary>> = webp
    end

    test "rejects garbage bytes without raising" do
      assert {:error, reason} = Encoder.to_webp(<<1, 2, 3, 4, 5>>)
      assert is_binary(reason) or is_atom(reason)
    end

    test "rejects empty input before decoding" do
      assert {:error, :empty} = Encoder.to_webp("", [])
    end

    test "rejects inputs above the byte cap before decoding" do
      oversized = String.duplicate("x", 11 * 1024 * 1024)
      assert {:error, :too_large} = Encoder.to_webp(oversized, [])
    end

    test "rejects images above the megapixel cap after decode" do
      limits = %Limits{max_megapixels: 0}
      # max_megapixels 0 rejects any image after successful decode.
      assert {:error, :too_many_pixels} =
               Encoder.to_webp(png_fixture(), limits: limits)
    end

    test "honours quality option (higher quality is not smaller here, but must succeed)" do
      assert {:ok, _webp} = Encoder.to_webp(png_fixture(), quality: 95)
      assert {:ok, _webp} = Encoder.to_webp(png_fixture(), quality: 40)
    end
  end

  describe "adapter/0" do
    test "resolves the configured Vix adapter by default" do
      assert Encoder.adapter() == Encoder.Vix
    end
  end
end
