defmodule Crysa.Images.LimitsTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Crysa.Images.Limits

  describe "validate_input/2" do
    test "accepts binaries within the byte cap" do
      assert :ok = Limits.validate_input("jpeg-bytes", Limits.defaults())
    end

    test "rejects empty and oversized inputs" do
      assert {:error, :empty} = Limits.validate_input("", Limits.defaults())

      oversized = String.duplicate("x", 11 * 1024 * 1024)
      assert {:error, :too_large} = Limits.validate_input(oversized, Limits.defaults())
    end

    test "validates files by size" do
      path = Path.join(System.tmp_dir!(), "crysa-limits-#{System.unique_integer()}")
      File.write!(path, "data")
      on_exit(fn -> File.rm(path) end)

      assert :ok = Limits.validate_input({:file, path}, Limits.defaults())

      assert {:error, :unreadable} =
               Limits.validate_input({:file, "/nonexistent/x"}, Limits.defaults())
    end

    test "rejects invalid sources" do
      assert {:error, :invalid_source} = Limits.validate_input(:not_a_source, Limits.defaults())
    end
  end

  describe "validate_dimensions/3" do
    test "enforces the megapixel cap" do
      limits = Limits.defaults()
      assert :ok = Limits.validate_dimensions(8000, 5000, limits)
      assert {:error, :too_many_pixels} = Limits.validate_dimensions(10_000, 10_000, limits)
    end
  end

  describe "with_timeout/2" do
    test "returns the result when under the timeout" do
      assert {:ok, :done} = Limits.with_timeout(fn -> :done end, Limits.defaults())
    end

    test "returns {:error, :timeout} and shuts the task down" do
      limits = %Limits{encode_timeout_ms: 20}

      assert {:error, :timeout} =
               Limits.with_timeout(
                 fn ->
                   Process.sleep(:infinity)
                 end,
                 limits
               )
    end

    test "a crashed task is reported as encode_crashed, not timeout (P7-7)" do
      assert {:error, {:encode_crashed, {reason, _stack}}} =
               Limits.with_timeout(
                 fn ->
                   raise "boom"
                 end,
                 Limits.defaults()
               )

      assert %RuntimeError{message: "boom"} = reason
    end
  end
end
