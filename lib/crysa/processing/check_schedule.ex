defmodule Crysa.Processing.CheckSchedule do
  @moduledoc """
  Status-derived check scheduling policy for series.

  Pure functions, kept under test (plan decision #12). Two adjustment layers
  stay separate:

    * **Base interval** — the nullable `manual_check_interval_minutes`
      override, or a status-derived default: `ongoing` → random 75–120
      minutes, `hiatus` → 4 hours, `completed` → 24 hours,
      `discontinued` → not scheduled at all.
    * **Failure backoff** — `2^check_retry_count` multiplier capped at ×32,
      decaying implicitly because successful checks reset the counter to
      zero.

  `next_check_at/3` combines both layers and adds proportional jitter of
  about ±10% of the interval (replacing Castra's fixed ±300 s, which is
  negligible for long intervals).
  """

  alias Crysa.Catalog.Series

  @ongoing_range 75..120
  @hiatus_minutes 240
  @completed_minutes 1_440

  @max_backoff_exponent 5
  @jitter_fraction 0.1

  @type interval_minutes :: pos_integer()

  @doc """
  Effective base interval in minutes for `series`.

  Returns `nil` when the series is unschedulable (`discontinued`) or no
  status-derived default applies.
  """
  @spec base_interval_minutes(
          Series.t()
          | %{manual_check_interval_minutes: integer() | nil, publication_status: String.t()}
        ) ::
          interval_minutes() | nil
  def base_interval_minutes(series)

  def base_interval_minutes(%{manual_check_interval_minutes: minutes})
      when is_integer(minutes),
      do: minutes

  def base_interval_minutes(%{publication_status: "ongoing"}), do: Enum.random(@ongoing_range)
  def base_interval_minutes(%{publication_status: "hiatus"}), do: @hiatus_minutes
  def base_interval_minutes(%{publication_status: "completed"}), do: @completed_minutes
  def base_interval_minutes(_series), do: nil

  @doc """
  Backoff multiplier for `retry_count` consecutive failures:
  `min(2^retry_count, 32)`.
  """
  @spec backoff_multiplier(non_neg_integer()) :: number()
  def backoff_multiplier(retry_count) when is_integer(retry_count) and retry_count >= 0 do
    Integer.pow(2, min(retry_count, @max_backoff_exponent))
  end

  @doc """
  Computes the next check instant.

  * `discontinued` (or unknown status) series return `nil` — never scheduled.
  * Otherwise `now + base × backoff ± proportional jitter`.
  """
  @spec next_check_at(DateTime.t(), Series.t() | map(), keyword()) ::
          DateTime.t() | nil
  def next_check_at(now, series, opts \\ []) do
    case base_interval_minutes(series) do
      nil ->
        nil

      base ->
        retry_count = Map.get(series, :check_retry_count) || 0
        jitter_enabled? = Keyword.get(opts, :jitter?, true)
        minutes = apply_jitter(base * backoff_multiplier(retry_count), jitter_enabled?)

        DateTime.add(now, round(minutes * 60), :second)
    end
  end

  @doc "Effective interval display value in minutes (nil when unscheduled)."
  @spec effective_interval_minutes(Series.t() | map()) :: interval_minutes() | nil
  def effective_interval_minutes(series) do
    case base_interval_minutes(series) do
      nil -> nil
      base -> base * backoff_multiplier(Map.get(series, :check_retry_count) || 0)
    end
  end

  defp apply_jitter(minutes, false), do: minutes

  defp apply_jitter(minutes, true) do
    spread = max(round(minutes * @jitter_fraction), 1)
    minutes + Enum.random(-spread..spread)
  end

  @doc "Statuses eligible for check scheduling."
  @spec schedulable_statuses() :: [String.t()]
  def schedulable_statuses, do: ~w(ongoing hiatus completed)
end
