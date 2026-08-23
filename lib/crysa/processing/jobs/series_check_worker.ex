defmodule Crysa.Processing.Jobs.SeriesCheckWorker do
  @moduledoc """
  Checks a single series for new chapters.

  Captures the published scraping config snapshot at job start, runs the
  `Crysa.Processing.SeriesCheck` engine and reschedules the series:

    * success → `check_retry_count = 0`, `next_check_at = now + base ± jitter`
    * failure → `check_retry_count += 1`,
      `next_check_at = now + base × backoff ± jitter`, bounded `last_error`

  Returning `{:error, _}` lets Oban retry transient infrastructure failures;
  the series-level backoff above covers repeated scraping failures.
  """

  use Oban.Worker,
    queue: :series_checks,
    max_attempts: 3,
    unique: [keys: [:series_id], states: :incomplete, period: :infinity]

  alias Crysa.Catalog
  alias Crysa.Processing.CheckSchedule
  alias Crysa.Processing.SeriesCheck
  alias Crysa.Repo
  alias Crysa.Scraping

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"series_id" => series_id}} = job) do
    case Repo.get(Catalog.Series, series_id) do
      nil ->
        {:ok, :series_gone}

      %Catalog.Series{} = series ->
        with {:ok, snapshot} <- resolve_snapshot(series) do
          check(series, snapshot, job)
        end
    end
  end

  @doc """
  Optional fetch override for tests (`config :crysa, __MODULE__, fetch_html: fun`).
  """
  def fetch_override do
    :crysa
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:fetch_html)
  end

  defp check(series, snapshot, _job) do
    opts =
      case fetch_override() do
        nil -> []
        fun -> [fetch_html: fun]
      end

    case SeriesCheck.run(series, snapshot, opts) do
      {:ok, _outcome} ->
        case record_success(series) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        record_failure(series, inspect(reason))
        {:error, reason}
    end
  end

  defp resolve_snapshot(series) do
    host = host_of(series.source_url)

    case Scraping.published_config_for_host(host) do
      {:ok, snapshot} -> {:ok, snapshot}
      {:error, reason} -> {:error, {:no_site_config, reason}}
    end
  end

  defp record_success(series) do
    now = DateTime.utc_now()

    schedule_input = %{
      manual_check_interval_minutes: series.manual_check_interval_minutes,
      publication_status: series.publication_status,
      check_retry_count: 0
    }

    Catalog.update_series(series, %{
      last_checked_at: now,
      check_retry_count: 0,
      last_error: nil,
      next_check_at: CheckSchedule.next_check_at(now, schedule_input)
    })
  end

  defp record_failure(series, message) do
    now = DateTime.utc_now()
    retry_count = (series.check_retry_count || 0) + 1

    # Compute scheduling input without mutating the persisted struct first:
    # a pre-mutated struct makes the identical changeset attr a no-change.
    schedule_input = %{
      manual_check_interval_minutes: series.manual_check_interval_minutes,
      publication_status: series.publication_status,
      check_retry_count: retry_count
    }

    Catalog.update_series(series, %{
      last_checked_at: now,
      check_retry_count: retry_count,
      last_error: String.slice(message, 0, 2_000),
      next_check_at: CheckSchedule.next_check_at(now, schedule_input)
    })
  end

  defp host_of(url) do
    case URI.parse(url || "") do
      %URI{host: host} when is_binary(host) -> host
      _ -> "unknown"
    end
  end
end
