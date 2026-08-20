defmodule Crysa.LibraryConcurrencyTest do
  @moduledoc """
  Concurrency tests for bookmark/rating uniqueness and counter consistency.

  These tests run the database work inside `Sandbox.unboxed_run/2`, i.e. with
  real pooled connections and independent transactions, so concurrent callers
  genuinely compete for row locks. Because this bypasses the SQL sandbox,
  every test creates unique rows and cleans them up via `on_exit`.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias Crysa.Accounts.User
  alias Crysa.AccountsFixtures
  alias Crysa.Catalog.Series
  alias Crysa.CatalogFixtures
  alias Crysa.Library
  alias Crysa.Library.{Bookmark, Rating, RatingChange, SeriesViewLog}
  alias Crysa.Repo

  @timeout 30_000

  setup_all do
    # Pre-create every role serially so concurrent user_fixture calls never
    # race to insert the same role row.
    unboxed(fn -> Enum.each(~w(superadmin admin moderator user), &AccountsFixtures.role/1) end)
    :ok
  end

  describe "bookmarks" do
    test "concurrent bookmarking by many users keeps the counter consistent" do
      unboxed(fn ->
        {series, users} = seed_unboxed(8)
        register_cleanup(series, users)

        results = run_concurrently(users, fn user -> Library.bookmark_series(user, series) end)

        assert Enum.all?(results, &match?({:ok, %Bookmark{}}, &1))
        assert %Series{bookmark_count: 8} = Repo.get!(Series, series.id)
        assert Repo.aggregate(bookmarks_for(series.id), :count, :id) == 8
      end)
    end

    test "concurrent bookmarking by one user never duplicates" do
      unboxed(fn ->
        {series, [user | _]} = seed_unboxed(1)
        register_cleanup(series, [user])

        results =
          run_concurrently(Enum.to_list(1..8), fn _ -> Library.bookmark_series(user, series) end)

        assert Enum.all?(results, &match?({:ok, %Bookmark{}}, &1))
        assert %Series{bookmark_count: 1} = Repo.get!(Series, series.id)
        assert Repo.aggregate(bookmarks_for(series.id), :count, :id) == 1
      end)
    end
  end

  describe "ratings" do
    test "concurrent ratings by many users keep count and sum consistent" do
      unboxed(fn ->
        {series, users} = seed_unboxed(5)
        register_cleanup(series, users)

        user_ratings = Enum.zip(users, [1, 2, 3, 4, 5])

        results =
          run_concurrently(user_ratings, fn {user, value} ->
            Library.rate_series(user, series, value)
          end)

        assert Enum.all?(results, &match?({:ok, %RatingChange{created?: true}}, &1))

        series = Repo.get!(Series, series.id)
        assert series.rating_count == 5
        assert series.rating_sum == 15
        assert Repo.aggregate(ratings_for(series.id), :count, :id) == 5
      end)
    end

    test "concurrent rating updates by one user leave one row and a matching sum" do
      unboxed(fn ->
        {series, [user | _]} = seed_unboxed(1)
        register_cleanup(series, [user])

        {:ok, _} = Library.rate_series(user, series, 5)

        results =
          run_concurrently(Enum.to_list(1..5), fn value ->
            Library.rate_series(user, series, value)
          end)

        assert Enum.all?(results, &match?({:ok, %RatingChange{}}, &1))

        series = Repo.get!(Series, series.id)

        rating =
          Repo.one!(from(r in Rating, where: r.user_id == ^user.id and r.series_id == ^series.id))

        # Exactly one row survives and the aggregate always mirrors its value,
        # no matter which concurrent write committed last.
        assert series.rating_count == 1
        assert series.rating_sum == rating.rating
        assert series.rating_sum in 1..5
        assert Repo.aggregate(ratings_for(series.id), :count, :id) == 1
      end)
    end
  end

  describe "series views" do
    test "concurrent view recording counts every event exactly" do
      unboxed(fn ->
        {series, users} = seed_unboxed(3)
        register_cleanup(series, users)
        total = 12

        results =
          1..total
          |> Enum.map(fn index ->
            Task.async(fn ->
              Library.record_view(series, user: Enum.at(users, rem(index, 3)))
            end)
          end)
          |> Task.await_many(@timeout)

        assert Enum.all?(results, &match?({:ok, %SeriesViewLog{}}, &1))
        assert %Series{view_count: total} = Repo.get!(Series, series.id)

        assert Repo.aggregate(
                 from(v in SeriesViewLog, where: v.series_id == ^series.id),
                 :count,
                 :id
               ) == total
      end)
    end
  end

  defp unboxed(fun), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fun)

  defp seed_unboxed(count) do
    series = CatalogFixtures.series_fixture()
    users = for _ <- 1..count, do: AccountsFixtures.user_fixture()
    {series, users}
  end

  defp register_cleanup(series, users) do
    on_exit(fn -> unboxed(fn -> cleanup(series, users) end) end)
    :ok
  end

  defp run_concurrently(items, fun) do
    items
    |> Task.async_stream(fun,
      max_concurrency: 8,
      timeout: @timeout,
      ordered: false
    )
    |> Enum.map(fn
      {:ok, result} ->
        result

      {:exit, reason} ->
        raise "concurrent task exited: #{inspect(reason)}"
    end)
  end

  defp bookmarks_for(series_id) do
    from(b in Bookmark, where: b.series_id == ^series_id)
  end

  defp ratings_for(series_id) do
    from(r in Rating, where: r.series_id == ^series_id)
  end

  defp cleanup(series, users) do
    if users != [] do
      Repo.delete_all(from(u in User, where: u.id in ^Enum.map(users, & &1.id)))
    end

    Repo.delete!(series)
    :ok
  end
end
