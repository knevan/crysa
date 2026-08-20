defmodule Crysa.LibraryTest do
  use Crysa.DataCase, async: false

  alias Crysa.AccountsFixtures
  alias Crysa.Catalog.Series
  alias Crysa.CatalogFixtures
  alias Crysa.Library
  alias Crysa.Library.{Bookmark, Rating, RatingChange, SeriesViewLog}

  import Ecto.Query

  setup do
    user = AccountsFixtures.user_fixture()
    other_user = AccountsFixtures.user_fixture()
    series = CatalogFixtures.series_fixture()
    %{user: user, other_user: other_user, series: series}
  end

  describe "bookmarks" do
    test "bookmarking a series increments the counter and is idempotent", %{
      user: user,
      series: series
    } do
      assert series.bookmark_count == 0

      assert {:ok, bookmark} = Library.bookmark_series(user, series)
      assert bookmark.user_id == user.id
      assert bookmark.series_id == series.id
      assert Library.bookmarked?(user, series)
      assert %Bookmark{} = Library.get_bookmark(user, series)
      assert %{bookmark_count: 1} = reload_series(series)

      # Bookmarking again is a no-op that does not double-count.
      assert {:ok, _again} = Library.bookmark_series(user, series)
      assert %{bookmark_count: 1} = reload_series(series)
      assert count_bookmarks(series.id) == 1
    end

    test "unbookmarking decrements the counter and removes the row", %{
      user: user,
      series: series
    } do
      {:ok, _bookmark} = Library.bookmark_series(user, series)
      assert %{bookmark_count: 1} = reload_series(series)

      assert :ok = Library.unbookmark_series(user, series)
      refute Library.bookmarked?(user, series)
      refute Library.get_bookmark(user, series)
      assert %{bookmark_count: 0} = reload_series(series)
      assert count_bookmarks(series.id) == 0
    end

    test "unbookmarking when nothing is bookmarked is idempotent", %{
      user: user,
      series: series
    } do
      assert :ok = Library.unbookmark_series(user, series)
      assert %{bookmark_count: 0} = reload_series(series)
    end

    test "bookmarked?/2 is false before any bookmark", %{user: user, series: series} do
      refute Library.bookmarked?(user, series)
    end

    test "a bookmark belongs to a single user", %{
      user: user,
      other_user: other_user,
      series: series
    } do
      {:ok, _} = Library.bookmark_series(user, series)
      assert Library.bookmarked?(user, series)
      refute Library.bookmarked?(other_user, series)
    end

    test "list_user_bookmarks returns only the user's bookmarks, latest first", %{
      user: user,
      other_user: other_user,
      series: series
    } do
      later = CatalogFixtures.series_fixture()

      {:ok, _} = Library.bookmark_series(user, series)
      {:ok, _} = Library.bookmark_series(user, later)
      {:ok, _} = Library.bookmark_series(other_user, later)

      {listed, pagination} = Library.list_user_bookmarks(user)

      assert pagination.total_entries == 2
      # `later` was bookmarked after `series`, so it comes first.
      assert Enum.map(listed, & &1.id) == [later.id, series.id]
    end

    test "list_user_bookmarks applies bounded pagination", %{
      user: user,
      series: series
    } do
      series2 = CatalogFixtures.series_fixture()

      {:ok, _} = Library.bookmark_series(user, series)
      {:ok, _} = Library.bookmark_series(user, series2)

      {listed, pagination} = Library.list_user_bookmarks(user, %{"page" => 1, "page_size" => 1})
      assert [_] = listed
      assert pagination.total_pages == 2
      assert pagination.total_entries == 2

      {page_two, _} = Library.list_user_bookmarks(user, %{"page" => 2, "page_size" => 1})
      assert [_] = page_two
      refute hd(listed).id == hd(page_two).id

      # Out-of-range page clamps to the last page.
      {clamped, clamped_pagination} =
        Library.list_user_bookmarks(user, %{"page" => 99, "page_size" => 1})

      assert [_] = clamped
      assert clamped_pagination.page == 2
    end

    test "list_user_bookmarks tolerates malformed pagination inputs", %{
      user: user,
      series: series
    } do
      {:ok, _} = Library.bookmark_series(user, series)

      # Non-numeric inputs fall back to defaults.
      {listed, pagination} =
        Library.list_user_bookmarks(user, %{"page" => "abc", "page_size" => "xyz"})

      assert [_] = listed
      assert pagination.page == 1
      assert pagination.page_size == 24

      # Zero/negative page and page_size are clamped to safe minima.
      {_, pagination} = Library.list_user_bookmarks(user, %{"page" => 0, "page_size" => 0})
      assert pagination.page == 1
      assert pagination.page_size == 1

      # Oversized page_size is clamped to the configured upper bound.
      {_, pagination} = Library.list_user_bookmarks(user, %{"page" => -5, "page_size" => 999})
      assert pagination.page == 1
      assert pagination.page_size == 60
    end
  end

  describe "ratings" do
    test "rating a series creates the aggregates", %{user: user, series: series} do
      assert series.rating_count == 0
      assert series.rating_sum == 0

      assert {:ok, %RatingChange{created?: true, previous_rating: nil, rating: rating}} =
               Library.rate_series(user, series, 4)

      assert rating.rating == 4
      assert %Rating{rating: 4} = Library.get_rating(user, series)

      assert %{count: 1, sum: 4, average: 4.0} =
               series |> reload_series() |> Library.rating_summary()
    end

    test "re-rating updates the sum without changing the count", %{
      user: user,
      series: series
    } do
      {:ok, _} = Library.rate_series(user, series, 4)

      assert {:ok, %RatingChange{created?: false, previous_rating: 4, rating: rating}} =
               Library.rate_series(user, series, 2)

      assert rating.rating == 2

      series = reload_series(series)
      assert %{count: 1, sum: 2} = Library.rating_summary(series)
      assert count_ratings(series.id) == 1
    end

    test "rating the same value leaves the counters unchanged", %{user: user, series: series} do
      {:ok, _} = Library.rate_series(user, series, 3)

      assert {:ok, %RatingChange{created?: false, rating: rating}} =
               Library.rate_series(user, series, 3)

      assert rating.rating == 3

      series = reload_series(series)
      assert %{count: 1, sum: 3} = Library.rating_summary(series)
    end

    test "unrate_series removes the aggregates", %{user: user, series: series} do
      {:ok, _} = Library.rate_series(user, series, 5)

      assert series |> reload_series() |> Library.rating_summary() == %{
               count: 1,
               sum: 5,
               average: 5.0
             }

      assert :ok = Library.unrate_series(user, series)
      refute Library.get_rating(user, series)

      series = reload_series(series)
      assert %{count: 0, sum: 0, average: nil} = Library.rating_summary(series)
      assert count_ratings(series.id) == 0
    end

    test "unrate_series when nothing is rated is idempotent", %{user: user, series: series} do
      assert :ok = Library.unrate_series(user, series)
    end

    test "rejects out-of-range ratings", %{user: user, series: series} do
      for invalid <- [0, 6, "four", nil] do
        assert {:error, changeset} = Library.rate_series(user, series, invalid)
        refute changeset.valid?
        assert changeset.errors[:rating]
      end

      assert %{count: 0, sum: 0} = series |> reload_series() |> Library.rating_summary()
    end

    test "different users rate the same series independently", %{
      user: user,
      other_user: other_user,
      series: series
    } do
      {:ok, _} = Library.rate_series(user, series, 3)
      {:ok, _} = Library.rate_series(other_user, series, 5)

      series = reload_series(series)
      assert %{count: 2, sum: 8, average: 4.0} = Library.rating_summary(series)
      assert %Rating{rating: 3} = Library.get_rating(user, series)
      assert %Rating{rating: 5} = Library.get_rating(other_user, series)
    end
  end

  describe "series views" do
    test "record_view persists an event and increments the view count", %{
      user: user,
      series: series
    } do
      assert series.view_count == 0

      assert {:ok, view_log} = Library.record_view(series, user: user, ip: "10.0.0.1")
      assert view_log.series_id == series.id
      assert view_log.user_id == user.id

      # IP/user agent are stored hashed, never raw.
      assert view_log.ip_hash == :crypto.hash(:sha256, "10.0.0.1") |> binary_part(0, 16)
      assert byte_size(view_log.ip_hash) == 16

      assert %{view_count: 1} = reload_series(series)
      assert count_view_logs(series.id) == 1
    end

    test "record_view without user metadata is allowed", %{series: series} do
      assert {:ok, view_log} = Library.record_view(series)
      assert is_nil(view_log.user_id)
      assert is_nil(view_log.ip_hash)
      assert is_nil(view_log.user_agent_hash)
      assert %{view_count: 1} = reload_series(series)
    end

    test "every record_view call counts", %{user: user, series: series} do
      for _ <- 1..3 do
        assert {:ok, _} = Library.record_view(series, user: user)
      end

      assert %{view_count: 3} = reload_series(series)
      assert count_view_logs(series.id) == 3
    end

    test "delete_old_views removes only rows older than the cutoff", %{
      user: user,
      series: series
    } do
      {:ok, _} = Library.record_view(series, user: user)

      old_cutoff = DateTime.add(DateTime.utc_now(), -3600, :second)
      new_cutoff = DateTime.add(DateTime.utc_now(), 3600, :second)

      # Note: cutoffs use generous slack so sub-second wall-clock skew (e.g.
      # WSL time syncing) never makes this assertion racy.
      assert Library.delete_old_views(old_cutoff) == 0
      assert count_view_logs(series.id) == 1

      assert Library.delete_old_views(new_cutoff) == 1
      assert count_view_logs(series.id) == 0
    end

    test "delete_old_views removes rows whose inserted_at equals the cutoff", %{
      series: series
    } do
      {:ok, view_log} = Library.record_view(series)

      # Pin the row's timestamp so the boundary is fully deterministic and
      # immune to wall-clock skew.
      boundary = DateTime.utc_now()
      {:ok, _} = view_log |> Ecto.Changeset.change(inserted_at: boundary) |> Repo.update()

      assert Library.delete_old_views(boundary) == 1
      assert count_view_logs(series.id) == 0
    end

    test "count_views_before groups view log rows by series", %{
      user: user,
      series: series
    } do
      other = CatalogFixtures.series_fixture()

      {:ok, _} = Library.record_view(series, user: user)
      {:ok, _} = Library.record_view(series)
      {:ok, _} = Library.record_view(other)

      # Cutoff derived from stored timestamps is immune to wall-clock skew.
      newest =
        from(v in SeriesViewLog, order_by: [desc: v.inserted_at], limit: 1)
        |> Repo.one!()

      assert Library.count_views_before(newest.inserted_at)
             |> Enum.sort() ==
               [{series.id, 2}, {other.id, 1}]
    end
  end

  defp reload_series(%Series{} = series), do: Repo.get!(Series, series.id)

  defp count_bookmarks(series_id) do
    Repo.aggregate(
      from(b in Bookmark, where: b.series_id == ^series_id),
      :count,
      :id
    )
  end

  defp count_ratings(series_id) do
    Repo.aggregate(
      from(r in Rating, where: r.series_id == ^series_id),
      :count,
      :id
    )
  end

  defp count_view_logs(series_id) do
    Repo.aggregate(
      from(v in SeriesViewLog, where: v.series_id == ^series_id),
      :count,
      :id
    )
  end
end
