defmodule Crysa.Images.Limits do
  @moduledoc """
  Resource limits applied around image conversion work.

  Strict safeguards required by the plan: max input bytes, max dimensions /
  megapixels and an encode timeout. Byte-size checks run before decoding;
  dimension checks belong to the native encoder implementation, which is the
  only place pixel data is inspected.
  """

  @max_input_bytes 10 * 1024 * 1024
  @max_megapixels 40
  @encode_timeout_ms 30_000

  @typedoc "Resolved limit set."
  @type t :: %__MODULE__{
          max_input_bytes: pos_integer(),
          max_megapixels: pos_integer(),
          encode_timeout_ms: pos_integer()
        }

  defstruct max_input_bytes: @max_input_bytes,
            max_megapixels: @max_megapixels,
            encode_timeout_ms: @encode_timeout_ms

  @doc "Default limit set."
  @spec defaults() :: t()
  def defaults, do: %__MODULE__{}

  @doc """
  Validates raw input against the byte-size cap.

  Returns `:ok` or `{:error, :too_large}` / `{:error, :empty}`.
  """
  @spec validate_input(binary() | {:file, Path.t()}, t()) :: :ok | {:error, term()}
  def validate_input(data, %__MODULE__{} = limits) when is_binary(data) do
    cond do
      byte_size(data) == 0 -> {:error, :empty}
      byte_size(data) > limits.max_input_bytes -> {:error, :too_large}
      true -> :ok
    end
  end

  def validate_input({:file, path}, %__MODULE__{} = limits) when is_binary(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: 0}} ->
        {:error, :empty}

      {:ok, %File.Stat{size: size}} when size > limits.max_input_bytes ->
        {:error, :too_large}

      {:ok, %File.Stat{}} ->
        :ok

      {:error, _} ->
        {:error, :unreadable}
    end
  end

  def validate_input(_other, _limits), do: {:error, :invalid_source}

  @doc "Validates decoded dimensions against the megapixel cap."
  @spec validate_dimensions(pos_integer(), pos_integer(), t()) :: :ok | {:error, :too_many_pixels}
  def validate_dimensions(width, height, %__MODULE__{} = limits)
      when is_integer(width) and is_integer(height) do
    if width * height > limits.max_megapixels * 1_000_000 do
      {:error, :too_many_pixels}
    else
      :ok
    end
  end

  @doc """
  Runs `fun` under the encode timeout.

  Outcomes are distinguished so failures are not misreported:

    * `{:ok, result}` — completed in time.
    * `{:error, {:encode_crashed, reason}}` — the task exited (raised or exited);
      surfacing this preserves the root cause instead of blaming the timeout.
    * `{:error, :timeout}` — exceeded `encode_timeout_ms`; the task is shut down.
  """
  @spec with_timeout((-> result), t()) ::
          {:ok, result} | {:error, :timeout | {:encode_crashed, term()}}
        when result: var
  def with_timeout(fun, %__MODULE__{encode_timeout_ms: timeout}) do
    task = Task.async(fun)
    # Trap exits so a crashing task surfaces as data ({:exit, reason}) via
    # Task.yield instead of killing this process with the raw exit.
    original_flag = Process.flag(:trap_exit, true)

    result =
      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} ->
          {:ok, result}

        {:exit, reason} ->
          {:error, {:encode_crashed, reason}}

        nil ->
          {:error, :timeout}
      end

    Process.flag(:trap_exit, original_flag)

    # Flush the EXIT message from a killed/crashed task so it cannot pollute
    # the caller's mailbox.
    receive do
      {:EXIT, ^task, _reason} -> :ok
    after
      0 -> :ok
    end

    result
  end
end
