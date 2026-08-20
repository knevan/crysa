defmodule Crysa.Library.Query do
  @moduledoc """
  Read-model queries for the Library context.

  Bundles bounded, parameterized queries for bookmarks and series view log
  aggregation/cleanup. User-provided pagination input is parsed and clamped
  here, mirroring `Crysa.Catalog.Query`.
  """

  import Ecto.Query

  alias Crysa.Catalog.Series
  alias Crysa.Library.{Bookmark, SeriesViewLog}
  alias Crysa.Pagination
  alias Crysa.Repo

  @default_page_size 24
  @max_page_size 60

  @spec exists_bookmark?(integer(), integer()) :: boolean()
  def exists_bookmark?(user_id, series_id) when is_integer(user_id) and is_integer(series_id) do
    from(b in Bookmark, where: b.user_id == ^user_id and b.series_id == ^series_id)
    |> Repo.exists?()
  end

  @spec list_user_bookmarks(integer(), map()) :: {[Series.t()], Pagination.t()}
  def list_user_bookmarks(user_id, params \\ %{})
      when is_integer(user_id) and is_map(params) do
    page = parse_page(params)
    page_size = parse_page_size(params)

    base = from(b in Bookmark, where: b.user_id == ^user_id)

    total = Repo.aggregate(base, :count, :id)
    page = clamp_page(page, page_size, total)

    bookmarks =
      base
      |> join(:inner, [b], s in assoc(b, :series))
      |> order_by([b, _s], desc: b.inserted_at, desc: b.id)
      |> select([_b, s], s)
      |> limit(^page_size)
      |> offset(^((page - 1) * page_size))
      |> Repo.all()

    {bookmarks, Pagination.build(page, page_size, total)}
  end

  @doc """
  Deletes series view log rows up to and including `cutoff`.

  The bound is inclusive to match `count_views_before/1`: every row the
  aggregation job counts is exactly the set this cleanup deletes, so a row
  can never be counted twice across consecutive passes. Intended for the
  bounded retention cleanup job that runs periodically; it is idempotent so
  a crashed job can safely run again.
  """
  @spec delete_old_views(DateTime.t()) :: non_neg_integer()
  def delete_old_views(cutoff) do
    from(v in SeriesViewLog, where: v.inserted_at <= ^cutoff)
    |> Repo.delete_all()
  end

  @doc """
  Groups view log rows up to `cutoff` by series.

  The write-behind aggregation job should apply these counts to
  `series.view_count` in batch form and then delete the consumed rows, instead
  of incrementing the counter per request. Currently the synchronous
  `Crysa.Library.record_view/2` increment is the source of truth; when the
  aggregation job is enabled the synchronous increment must be turned off to
  avoid double counting.
  """
  @spec count_views_before(DateTime.t()) :: [{integer(), non_neg_integer()}]
  def count_views_before(cutoff) do
    from(v in SeriesViewLog,
      where: v.inserted_at <= ^cutoff,
      group_by: v.series_id,
      select: {v.series_id, count(v.id)}
    )
    |> Repo.all()
  end

  defp parse_page(params) do
    case parse_integer(params, "page", 1) do
      page when page > 0 -> page
      _ -> 1
    end
  end

  # Clamp the requested page to the last existing page so out-of-range
  # values cannot produce unbounded offsets.
  defp clamp_page(page, page_size, total) do
    total_pages = max(div(total + page_size - 1, page_size), 1)
    min(page, total_pages)
  end

  defp parse_page_size(params, default \\ @default_page_size, max \\ @max_page_size) do
    params
    |> parse_integer("page_size", default)
    |> clamp(1, max)
  end

  defp parse_integer(params, key, default) do
    case params do
      %{^key => value} when is_integer(value) ->
        value

      %{^key => value} when is_binary(value) ->
        case Integer.parse(value) do
          {int, ""} -> int
          _ -> default
        end

      _ ->
        default
    end
  end

  defp clamp(value, min, _max) when value < min, do: min
  defp clamp(value, _min, max) when value > max, do: max
  defp clamp(value, _min, _max), do: value
end
