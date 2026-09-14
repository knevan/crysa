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
  @type item :: %{
          id: integer(),
          title: String.t(),
          slug: String.t(),
          coverUrl: String.t() | nil,
          ratingAverage: float() | nil,
          chapterCount: non_neg_integer(),
          status: String.t(),
          genres: [String.t()],
          firstChapterKey: String.t() | nil
        }
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
  Patches the cached `ratingAverage` for `series_id` in every period list.

  Ratings never affect ranking (windows rank by view volume only), so a full
  recompute on every rating would waste a grouped query. The homepage is a
  plain controller with no LiveView subscription, so without this patch a
  refresh keeps serving the pre-rating snapshot until the period TTL expires
  (up to 30 minutes). Patching the display-only field in place makes the
  badge show up on the next refresh. Best-effort: never raises, no-op on
  cache miss or when the series is not in a list.
  """
  @spec patch_cached_rating(integer(), %{optional(atom()) => term()}) :: :ok
  def patch_cached_rating(series_id, summary)
      when is_integer(series_id) and is_map(summary) do
    average = rounded_summary_average(summary)
    Enum.each(@periods, &patch_period_rating(&1, series_id, average))
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
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
    series =
      from(s in Series, where: s.id in ^ids)
      |> Repo.all()
      |> Repo.preload(:categories)

    by_id = Map.new(series, fn item -> {item.id, item} end)
    first_chapters = Catalog.first_chapters_by_series(ids)

    ids
    |> Enum.map(&Map.get(by_id, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_item(&1, first_chapters))
  end

  defp to_item(%Series{} = series, first_chapters) do
    %{
      id: series.id,
      title: series.title,
      slug: series.slug,
      coverUrl: Catalog.cover_url(series),
      ratingAverage: rating_average(series),
      chapterCount: series.chapter_count || 0,
      status: series.publication_status,
      genres: series_genres(series),
      firstChapterKey: first_chapter_key(first_chapters, series.id)
    }
  end

  # Display names sorted for stability, capped so hero genre badges
  # stay a single row. Unassociated series get an empty list.
  defp series_genres(%Series{categories: categories}) when is_list(categories) do
    categories
    |> Enum.map(& &1.name)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort()
    |> Enum.take(3)
  end

  defp series_genres(_), do: []

  defp first_chapter_key(first_chapters, series_id) do
    case Map.get(first_chapters, series_id) do
      %{chapter_key: key} -> key
      _ -> nil
    end
  end

  defp rating_average(%Series{rating_count: count, rating_sum: sum})
       when is_integer(count) and count > 0 and is_number(sum) do
    Float.round(sum / count, 1)
  end

  defp rating_average(_), do: nil

  defp rounded_summary_average(%{count: count, average: average})
       when is_integer(count) and count > 0 and is_number(average) do
    Float.round(average, 1)
  end

  defp rounded_summary_average(_), do: nil

  defp patch_period_rating(period, series_id, average) do
    key = cache_key(period)

    case Cachex.get(@cache, key) do
      {:ok, %{items: items} = result} when is_list(items) ->
        if Enum.any?(items, &(&1.id == series_id)) do
          patched = Enum.map(items, &maybe_patch_item(&1, series_id, average))
          Cachex.put(@cache, key, %{result | items: patched}, expire: ttl_ms(period))
        end

        :ok

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp maybe_patch_item(%{id: id} = item, series_id, average) when id == series_id do
    %{item | ratingAverage: average}
  end

  defp maybe_patch_item(item, _series_id, _average), do: item

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
