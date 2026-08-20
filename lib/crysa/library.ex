defmodule Crysa.Library do
  @moduledoc """
  Library context for bookmarks, ratings, and series view events.

  Every operation that mutates a `series` aggregate counter (bookmark count,
  rating count/sum, view count) runs inside a database transaction together
  with the row-level change, so the counters never drift from the underlying
  rows.

  Bookmark and rating flows serialize on the affected `series` row via
  `FOR UPDATE` so concurrent callers cannot interleave and corrupt the
  counters. View recording is append-only and increments the counter with an
  atomic `inc`, so it needs no row lock and cannot lose updates.
  """

  alias Crysa.Accounts.User
  alias Crysa.Catalog.Series
  alias Crysa.Library.{Bookmark, Query, Rating, RatingChange, SeriesViewLog}
  alias Crysa.Repo

  import Ecto.Query

  @doc """
  Bookmarks a series for a user.

  Idempotent: if a bookmark already exists it is returned as-is and the
  counter is not incremented again.
  """
  @spec bookmark_series(User.t(), Series.t()) ::
          {:ok, Bookmark.t()} | {:error, Ecto.Changeset.t()}
  def bookmark_series(%User{id: user_id}, %Series{id: series_id}) do
    in_transaction(fn ->
      series = lock_series!(series_id)

      case Repo.get_by(Bookmark, user_id: user_id, series_id: series_id) do
        nil -> insert_bookmark(series, user_id, series_id)
        bookmark -> {:ok, bookmark}
      end
    end)
  end

  @doc """
  Removes a user's bookmark for a series, decrementing the counter.

  Idempotent: removing a bookmark that does not exist is `:ok`.
  """
  @spec unbookmark_series(User.t(), Series.t()) :: :ok | {:error, term()}
  def unbookmark_series(%User{id: user_id}, %Series{id: series_id}) do
    in_transaction(fn ->
      series = lock_series!(series_id)

      case Repo.get_by(Bookmark, user_id: user_id, series_id: series_id) do
        nil ->
          :ok

        bookmark ->
          Repo.delete!(bookmark)
          adjust_counter(series, :bookmark_count, -1)
          :ok
      end
    end)
  end

  @spec bookmarked?(User.t(), Series.t()) :: boolean()
  def bookmarked?(%User{id: user_id}, %Series{id: series_id}) do
    Query.exists_bookmark?(user_id, series_id)
  end

  @spec get_bookmark(User.t(), Series.t()) :: Bookmark.t() | nil
  def get_bookmark(%User{id: user_id}, %Series{id: series_id}) do
    Repo.get_by(Bookmark, user_id: user_id, series_id: series_id)
  end

  @spec list_user_bookmarks(User.t(), map()) :: {[Series.t()], Crysa.Pagination.t()}
  def list_user_bookmarks(%User{id: user_id}, params \\ %{}) when is_map(params),
    do: Query.list_user_bookmarks(user_id, params)

  @doc """
  Creates or updates a user's rating for a series.

  Runs the rating upsert and the `rating_count`/`rating_sum` aggregate updates
  in one transaction. The resulting `Crysa.Library.RatingChange` tells the
  caller whether a rating was created, updated, or left unchanged.
  """
  @spec rate_series(User.t(), Series.t(), integer()) ::
          {:ok, RatingChange.t()} | {:error, Ecto.Changeset.t()}
  def rate_series(%User{id: user_id}, %Series{id: series_id}, rating) do
    changeset =
      %Rating{}
      |> Rating.changeset(%{user_id: user_id, series_id: series_id, rating: rating})

    if changeset.valid? do
      in_transaction(fn -> upsert_rating(changeset, user_id, series_id) end)
    else
      {:error, changeset}
    end
  end

  @doc """
  Removes a user's rating for a series, decrementing the aggregates.

  Idempotent: removing a rating that does not exist is `:ok`.
  """
  @spec unrate_series(User.t(), Series.t()) :: :ok | {:error, term()}
  def unrate_series(%User{id: user_id}, %Series{id: series_id}) do
    in_transaction(fn ->
      series = lock_series!(series_id)

      case find_rating_for_update(user_id, series_id) do
        nil ->
          :ok

        %Rating{rating: previous} = rating ->
          Repo.delete!(rating)
          adjust_counter(series, :rating_count, -1)
          adjust_counter(series, :rating_sum, -previous)
          :ok
      end
    end)
  end

  @spec get_rating(User.t(), Series.t()) :: Rating.t() | nil
  def get_rating(%User{id: user_id}, %Series{id: series_id}) do
    Repo.get_by(Rating, user_id: user_id, series_id: series_id)
  end

  @doc "Series rating aggregate plus a derived average (nil when nobody rated)."
  @spec rating_summary(Series.t()) :: %{
          count: non_neg_integer(),
          sum: non_neg_integer(),
          average: float() | nil
        }
  def rating_summary(%Series{rating_count: count, rating_sum: sum}) do
    average = if count > 0, do: sum / count, else: nil
    %{count: count, sum: sum, average: average}
  end

  @doc """
  Records a series view event and increments `series.view_count`.

  This is the initial simple strategy: one log row plus one atomic counter
  increment per event. When traffic grows, switch to the write-behind
  aggregation path (`Query.count_views_before/1` + bounded cleanup) prepared
  for the durable jobs in Phase 7.

  Accepted options: `:user`/`:user_id`, `:ip` and `:user_agent` (both hashed,
  never stored as plaintext).
  """
  @spec record_view(Series.t(), map()) :: {:ok, SeriesViewLog.t()} | {:error, Ecto.Changeset.t()}
  def record_view(%Series{id: series_id}, opts \\ %{}) do
    opts = Map.new(opts)

    attrs = %{
      series_id: series_id,
      user_id: normalize_user_id(opts),
      ip_hash: field_hash(opts[:ip]),
      user_agent_hash: field_hash(opts[:user_agent])
    }

    in_transaction(fn ->
      case SeriesViewLog.changeset(%SeriesViewLog{}, attrs) |> Repo.insert() do
        {:ok, view_log} ->
          increment_view_count(series_id)
          {:ok, view_log}

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  @doc "Deletes view log rows up to and including `cutoff`; returns the number removed."
  @spec delete_old_views(DateTime.t()) :: non_neg_integer()
  def delete_old_views(cutoff) do
    {count, _} = Query.delete_old_views(cutoff)
    count
  end

  @doc "Counts view log rows up to `cutoff` grouped by series."
  @spec count_views_before(DateTime.t()) :: [{integer(), non_neg_integer()}]
  def count_views_before(cutoff), do: Query.count_views_before(cutoff)

  defp insert_bookmark(%Series{} = series, user_id, series_id) do
    case Bookmark.changeset(%Bookmark{}, %{user_id: user_id, series_id: series_id})
         |> Repo.insert() do
      {:ok, bookmark} ->
        adjust_counter(series, :bookmark_count, 1)
        {:ok, bookmark}

      {:error, changeset} ->
        Repo.rollback(changeset)
    end
  end

  defp upsert_rating(changeset, user_id, series_id) do
    series = lock_series!(series_id)
    rating = changeset.changes[:rating]

    case find_rating_for_update(user_id, series_id) do
      nil ->
        create_rating(changeset, series)

      %Rating{rating: previous} = existing when previous == rating ->
        {:ok, %RatingChange{rating: existing, created?: false, previous_rating: previous}}

      %Rating{rating: previous} = existing ->
        update_rating(existing, rating, previous, series)
    end
  end

  defp create_rating(changeset, %Series{} = series) do
    case Repo.insert(changeset) do
      {:ok, rating} ->
        adjust_counter(series, :rating_count, 1)
        adjust_counter(series, :rating_sum, rating.rating)
        {:ok, %RatingChange{rating: rating, created?: true, previous_rating: nil}}

      {:error, changeset} ->
        Repo.rollback(changeset)
    end
  end

  defp update_rating(existing, rating, previous, %Series{} = series) do
    case existing |> Rating.changeset(%{rating: rating}) |> Repo.update() do
      {:ok, updated} ->
        adjust_counter(series, :rating_sum, rating - previous)
        {:ok, %RatingChange{rating: updated, created?: false, previous_rating: previous}}

      {:error, changeset} ->
        Repo.rollback(changeset)
    end
  end

  defp lock_series!(series_id) when is_integer(series_id),
    do: Repo.get!(Series, series_id, lock: "FOR UPDATE")

  # Locks the rating row itself so the concurrent upsert below cannot race
  # with another writer targeting the same (user, series) pair.
  defp find_rating_for_update(user_id, series_id) do
    from(r in Rating,
      where: r.user_id == ^user_id and r.series_id == ^series_id,
      lock: "FOR UPDATE"
    )
    |> Repo.one()
  end

  # Adjust an aggregate counter on a series row the caller already locked
  # (`FOR UPDATE`), so `Map.fetch!/2` reads the latest committed value and no
  # update can be lost. Counters are floored at zero defensively.
  defp adjust_counter(%Series{id: series_id} = series, field, delta) when is_integer(delta) do
    new_value = max(Map.fetch!(series, field) + delta, 0)

    from(s in Series, where: s.id == ^series_id, select: s)
    |> Repo.update_all(set: [{field, new_value}])
  end

  # Atomic `inc` requires no row lock: concurrent callers each add exactly one
  # to the same counter without lost updates.
  defp increment_view_count(series_id) when is_integer(series_id) do
    from(s in Series, where: s.id == ^series_id, select: s)
    |> Repo.update_all(inc: [view_count: 1])
  end

  defp normalize_user_id(opts) do
    case Map.get(opts, :user) || Map.get(opts, :user_id) do
      %User{id: id} -> id
      id when is_integer(id) -> id
      _ -> nil
    end
  end

  # Pseudonymize request metadata with a truncated SHA-256 digest so raw IPs
  # and user agents are never persisted.
  defp field_hash(value) when is_binary(value) and byte_size(value) > 0 do
    :crypto.hash(:sha256, value) |> binary_part(0, 16)
  end

  defp field_hash(_value), do: nil

  # Runs a function inside a transaction and normalizes Ecto's `{:ok, inner}`
  # wrapper so callers get the inner result directly. `Repo.rollback/1` values
  # surface as `{:error, reason}`, and unexpected database errors propagate as
  # `{:error, %Postgrex.Error{}}` or similar.
  defp in_transaction(fun) do
    case Repo.transaction(fun) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end
end
