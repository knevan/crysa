defmodule Crysa.Trending do
  @moduledoc """
  Windowed trending read model for the homepage carousel.

  Ranks series by chapter-read volume inside rolling windows (`hour`, `day`,
  `week`, `month`) instead of the all-time `series.view_count` counter, so a
  long-running popular title cannot permanently crowd out new viral ones.
  Windows are nested, so overlap between e.g. week and month is expected.

  Reads go through Cachex (`Crysa.Trending.Cache`) with a short per-period
  TTL; a miss recomputes from `series_view_log` with a single grouped query
  (concurrent misses for one key are coalesced by Cachex). Failures degrade
  to an empty list with a short TTL so the homepage never fails because of
  trending.
  """

  import Ecto.Query

  alias Crysa.Catalog
  alias Crysa.Catalog.Series
  alias Crysa.Library.SeriesViewLog
  alias Crysa.Repo

  require Logger

  @cache Crysa.Trending.Cache
  @limit 15
  @periods ~w(hour day week month)
  @ttls %{"hour" => 60_000, "day" => 300_000, "week" => 900_000, "month" => 1_800_000}
  @failure_ttl_ms 30_000

  @type period :: String.t()
  @type item :: %{id: integer(), title: String.t(), slug: String.t(), coverUrl: String.t() | nil}
  @type result :: %{items: [item()], computedAt: String.t()}
  @type lists :: %{period() => result()}

  @spec periods() :: [period()]
  def periods, do: @periods

  @spec limit() :: pos_integer()
  def limit, do: @limit

  @spec ttl_ms(period()) :: pos_integer()
  def ttl_ms(period), do: Map.fetch!(@ttls, normalize_period(period))

  @doc """
  Returns the cached top-`limit()` series for `period` with its compute time.

  Unknown periods fall back to `"day"`. Never raises: on failure returns an
  empty list (cached briefly to avoid hammering the database during outages).
  """
  @spec list_trending(period() | atom()) :: result()
  def list_trending(period) do
    period = normalize_period(period)
    started_at = System.monotonic_time()
    key = cache_key(period)

    result =
      Cachex.fetch(@cache, key, fn ->
        try do
          {:commit, compute_trending(period), expire: ttl_ms(period)}
        rescue
          error ->
            Logger.warning("trending recompute failed", period: period, error: inspect(error))
            {:commit, empty_result(), expire: @failure_ttl_ms}
        end
      end)

    case result do
      {:ok, value} ->
        emit_telemetry(period, true, started_at)
        value

      {:commit, value} ->
        emit_telemetry(period, false, started_at)
        value

      {:error, error} ->
        Logger.warning("trending cache unavailable", period: period, error: inspect(error))
        empty_result()
    end
  end

  @doc """
  Returns all four period lists at once for the homepage carousel.

  A single map keeps tab switches client-side with no extra roundtrips.
  Computed sequentially; each list is served from cache when warm.
  """
  @spec trending_lists() :: lists()
  def trending_lists do
    Map.new(@periods, fn period -> {period, list_trending(period)} end)
  end

  @doc """
  Best-effort preload of all period lists (boot warmer).

  Writes directly instead of going through `list_trending/1` so failures
  stay silent: a background warmer must never pollute logs, and the request
  path degrades to empty lists anyway.
  """
  @spec warm() :: :ok
  def warm do
    Enum.each(@periods, fn period ->
      try do
        value = fetch_live(period)
        Cachex.put(@cache, cache_key(period), value, expire: ttl_ms(period))
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end
    end)

    :ok
  end

  @doc """
  Uncached computation for a period. Public for tests; prefer
  `list_trending/1` in request paths.
  """
  @spec fetch_live(period() | atom()) :: result()
  def fetch_live(period) do
    period = normalize_period(period)
    compute_trending(period)
  end

  defp compute_trending(period) do
    now = DateTime.utc_now()
    cutoff = cutoff_for(period, now)

    counts =
      from(v in SeriesViewLog,
        where: v.inserted_at >= ^cutoff,
        join: s in Series,
        on: s.id == v.series_id,
        where: is_nil(s.archived_at),
        group_by: s.id,
        order_by: [desc: count(v.id), desc: s.id],
        limit: ^@limit,
        select: s.id
      )
      |> Repo.all()

    %{items: load_items(counts), computedAt: DateTime.to_iso8601(now)}
  end

  defp load_items([]), do: []

  defp load_items(ids) do
    by_id =
      from(s in Series, where: s.id in ^ids)
      |> Repo.all()
      |> Map.new(fn series -> {series.id, series} end)

    ids
    |> Enum.map(&Map.get(by_id, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_item/1)
  end

  defp to_item(%Series{} = series) do
    %{id: series.id, title: series.title, slug: series.slug, coverUrl: Catalog.cover_url(series)}
  end

  defp empty_result, do: %{items: [], computedAt: DateTime.to_iso8601(DateTime.utc_now())}

  defp cache_key(period), do: {:trending, period}

  defp normalize_period(period) when is_atom(period), do: normalize_period(Atom.to_string(period))
  defp normalize_period(period) when period in @periods, do: period
  defp normalize_period(_), do: "day"

  defp cutoff_for("hour", now), do: DateTime.add(now, -1, :hour)
  defp cutoff_for("day", now), do: DateTime.add(now, -1, :day)
  defp cutoff_for("week", now), do: DateTime.add(now, -7, :day)
  defp cutoff_for("month", now), do: DateTime.add(now, -30, :day)

  defp emit_telemetry(period, hit, started_at) do
    duration = System.monotonic_time() - started_at

    :telemetry.execute(
      [:crysa, :trending, :fetch],
      %{duration: duration},
      %{period: period, hit: hit}
    )
  end
end
