defmodule Crysa.TrendingTest do
  use Crysa.DataCase

  alias Crysa.CatalogFixtures
  alias Crysa.Library.SeriesViewLog
  alias Crysa.Repo
  alias Crysa.Trending

  @cache Crysa.Trending.Cache

  setup do
    Cachex.clear(@cache)
    :ok
  end

  defp log_view(series, inserted_at) do
    %SeriesViewLog{series_id: series.id, inserted_at: inserted_at}
    |> Repo.insert!()
  end

  defp hours_ago(n), do: DateTime.add(DateTime.utc_now(), -n, :hour)
  defp days_ago(n), do: DateTime.add(DateTime.utc_now(), -n, :day)

  describe "fetch_live/1" do
    test "ranks series by view count inside the window" do
      hot = CatalogFixtures.series_fixture()
      cold = CatalogFixtures.series_fixture()

      log_view(hot, hours_ago(1))
      log_view(hot, hours_ago(2))
      log_view(hot, hours_ago(3))
      log_view(cold, hours_ago(1))

      %{items: items} = Trending.fetch_live("day")

      assert [%{id: hot_id}, %{id: cold_id}] = items
      assert hot_id == hot.id
      assert cold_id == cold.id
    end

    test "ignores views outside the window" do
      series = CatalogFixtures.series_fixture()
      log_view(series, days_ago(8))

      assert %{items: []} = Trending.fetch_live("week")
      assert %{items: [%{id: id}]} = Trending.fetch_live("month")
      assert id == series.id
    end

    test "excludes archived series" do
      series = CatalogFixtures.series_fixture(%{archived_at: DateTime.utc_now()})
      log_view(series, hours_ago(1))

      assert %{items: []} = Trending.fetch_live("day")
    end

    test "is bounded to the carousel size" do
      for _ <- 1..16 do
        series = CatalogFixtures.series_fixture()
        log_view(series, hours_ago(1))
      end

      %{items: items} = Trending.fetch_live("day")
      assert length(items) == Trending.limit()
    end

    test "breaks count ties deterministically" do
      first = CatalogFixtures.series_fixture()
      second = CatalogFixtures.series_fixture()
      log_view(first, hours_ago(1))
      log_view(second, hours_ago(1))

      %{items: [%{id: top_id}, %{id: next_id}]} = Trending.fetch_live("day")
      assert {top_id, next_id} == {second.id, first.id}
    end

    test "falls back to day for unknown periods" do
      series = CatalogFixtures.series_fixture()
      log_view(series, hours_ago(1))

      assert Trending.fetch_live("bogus").items == Trending.fetch_live("day").items
    end
  end

  describe "list_trending/1" do
    test "serves stale cache until cleared" do
      old = CatalogFixtures.series_fixture()
      log_view(old, hours_ago(1))

      assert [%{id: old_id}] = Trending.list_trending("day").items
      assert old_id == old.id

      fresh = CatalogFixtures.series_fixture()
      log_view(fresh, minutes_ago(5))
      log_view(fresh, minutes_ago(6))

      # Still cached: fresh series not yet visible.
      assert [%{id: ^old_id}] = Trending.list_trending("day").items

      Cachex.clear(@cache)

      assert [%{id: fresh_id}, %{id: ^old_id}] = Trending.list_trending("day").items
      assert fresh_id == fresh.id
    end

    test "warm/0 preloads all periods without raising" do
      series = CatalogFixtures.series_fixture()
      log_view(series, minutes_ago(10))

      assert :ok = Trending.warm()

      for period <- Trending.periods() do
        assert {:ok, %{items: [%{id: id}]}} = Cachex.get(@cache, {:trending, period})
        assert id == series.id
      end
    end
  end

  describe "trending_lists/0" do
    test "returns all four periods with items and compute time" do
      series = CatalogFixtures.series_fixture()
      log_view(series, minutes_ago(10))

      lists = Trending.trending_lists()

      assert Map.keys(lists) |> Enum.sort() == ["day", "hour", "month", "week"]

      for {_period, result} <- lists do
        assert [%{id: id, title: title, slug: slug}] = result.items
        assert id == series.id
        assert is_binary(title) and is_binary(slug)
        assert {:ok, _, _} = DateTime.from_iso8601(result.computedAt)
      end
    end
  end

  describe "patch_cached_rating/2" do
    test "updates the badge on refresh without recompute" do
      series = CatalogFixtures.series_fixture(%{rating_count: 0, rating_sum: 0})
      log_view(series, minutes_ago(10))

      assert [%{id: id, ratingAverage: nil}] = Trending.list_trending("day").items
      assert id == series.id

      assert :ok =
               Trending.patch_cached_rating(series.id, %{count: 2, sum: 9.0, average: 4.5})

      assert [%{id: ^id, ratingAverage: 4.5}] = Trending.list_trending("day").items
    end

    test "clears the badge when the last rating is removed" do
      series = CatalogFixtures.series_fixture(%{rating_count: 1, rating_sum: 5.0})
      log_view(series, minutes_ago(10))

      assert [%{ratingAverage: 5.0}] = Trending.list_trending("day").items
      assert :ok = Trending.patch_cached_rating(series.id, %{count: 0, sum: 0, average: nil})
      assert [%{ratingAverage: nil}] = Trending.list_trending("day").items
    end

    test "is a no-op for series outside the list" do
      series = CatalogFixtures.series_fixture()
      log_view(series, minutes_ago(10))

      assert [%{id: id}] = Trending.list_trending("day").items
      assert :ok = Trending.patch_cached_rating(-1, %{count: 1, sum: 5.0, average: 5.0})
      assert [%{id: ^id, ratingAverage: nil}] = Trending.list_trending("day").items
    end
  end

  defp minutes_ago(n), do: DateTime.add(DateTime.utc_now(), -n, :minute)
end
