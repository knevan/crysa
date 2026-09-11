defmodule Crysa.Library.Query do
  @moduledoc """
  Read-model queries for the Library context.

  Bundles bounded, parameterized queries for bookmarks and series view log
  aggregation/cleanup. User-provided pagination input is parsed and clamped
  here, mirroring `Crysa.Catalog.Query`.
  """

  import Ecto.Query

  alias Crysa.Catalog.Chapter
  alias Crysa.Catalog.Series
  alias Crysa.Library.{Bookmark, ReadingProgress, SeriesViewLog}
  alias Crysa.Pagination
  alias Crysa.Repo

  @default_page_size 24
  @max_page_size 60

  @bookmark_statuses ~w(ongoing completed hiatus discontinued)
  @bookmark_sort_options ~w(latest_update bookmarked_at title)
  @bookmark_orders ~w(asc desc)

  @spec exists_bookmark?(integer(), integer()) :: boolean()
  def exists_bookmark?(user_id, series_id) when is_integer(user_id) and is_integer(series_id) do
    from(b in Bookmark, where: b.user_id == ^user_id and b.series_id == ^series_id)
    |> Repo.exists?()
  end

  @spec list_user_bookmarks(integer(), map()) :: {[Series.t()], Pagination.t()}
  def list_user_bookmarks(user_id, params \\ %{})
      when is_integer(user_id) and is_map(params) do
    {entries, pagination} = list_user_bookmark_entries(user_id, params)
    {Enum.map(entries, & &1.series), pagination}
  end

  @type bookmark_entry :: %{
          required(:bookmark) => Bookmark.t(),
          required(:series) => Series.t(),
          required(:latest_chapter) => Chapter.t() | nil,
          required(:last_read_chapter) => Chapter.t() | nil
        }

  @doc """
  Paginated bookmark library entries for the bookmark page.

  Returns `{entries, pagination}` where each entry carries the bookmark row
  (for `inserted_at` badge logic), the series row, the latest `available`
  chapter (or `nil` when the series has none), and the user's last read
  `available` chapter (or `nil` when the user never opened one).

  Supported params (all optional, allowlisted):

    * `"status"` — `publication_status` filter (`ongoing`, `completed`,
      `hiatus`, `discontinued`); `"all"` or anything else means no filter.
    * `"sort_by"` — `"latest_update"` (series `last_chapter_at`),
      `"bookmarked_at"` (bookmark `inserted_at`), `"title"`.
      Defaults to `"bookmarked_at"` so callers without UI params keep the
      historical newest-bookmark-first order.
    * `"order"` — `"asc"` / `"desc"`. Defaults to `"desc"`, except `title`
      which defaults to `"asc"`.
    * `"page"`, `"page_size"` — bounded pagination, same clamping as other
      read models.

  Archived series are excluded: bookmarks pointing at archived rows stay in
  the database but are hidden from the library surface.
  """
  @spec list_user_bookmark_entries(integer(), map()) :: {[bookmark_entry()], Pagination.t()}
  def list_user_bookmark_entries(user_id, params \\ %{})
      when is_integer(user_id) and is_map(params) do
    page = parse_page(params)
    page_size = parse_page_size(params)
    status = parse_bookmark_status(params)
    sort_by = parse_bookmark_sort(params)
    order = parse_bookmark_order(params, sort_by)

    base =
      from(b in Bookmark, where: b.user_id == ^user_id)
      |> join(:inner, [b], s in assoc(b, :series))
      |> where([_b, s], is_nil(s.archived_at))
      |> filter_bookmark_status(status)
      |> order_bookmarks(sort_by, order)

    total = Repo.aggregate(base, :count, :id)
    page = clamp_page(page, page_size, total)

    rows =
      base
      |> select([b, s], {b, s})
      |> limit(^page_size)
      |> offset(^((page - 1) * page_size))
      |> Repo.all()

    series_ids = rows |> Enum.map(fn {_b, s} -> s.id end) |> Enum.uniq()
    latest_by_series = latest_chapters_by_series(series_ids)
    last_read_by_series = last_read_chapters_for_user(user_id, series_ids)

    entries =
      Enum.map(rows, fn {bookmark, series} ->
        %{
          bookmark: bookmark,
          series: series,
          latest_chapter: Map.get(latest_by_series, series.id),
          last_read_chapter: Map.get(last_read_by_series, series.id)
        }
      end)

    {entries, Pagination.build(page, page_size, total)}
  end

  # Single batched lookup for the latest `available` chapter per series.
  # Uses Postgres `DISTINCT ON (series_id)` ordered by `sort_key DESC, id DESC`,
  # mirroring `Catalog.Query.get_latest_chapter/1`. Empty input short-circuits
  # to avoid an `IN ()` query.
  @spec latest_chapters_by_series([integer()]) :: %{integer() => Chapter.t()}
  defp latest_chapters_by_series([]), do: %{}

  defp latest_chapters_by_series(series_ids) do
    from(c in Chapter,
      where: c.series_id in ^series_ids and c.status == "available",
      distinct: c.series_id,
      order_by: [asc: c.series_id, desc: c.sort_key, desc: c.id]
    )
    |> Repo.all()
    |> Map.new(fn chapter -> {chapter.series_id, chapter} end)
  end

  # Single batched lookup for the user's last read `available` chapter per
  # series. Progress rows whose chapter was deleted (`last_chapter_id` nil)
  # or became unreadable are dropped by the join, so the card falls back
  # to `—` instead of linking to a dead reader URL.
  @doc """
  Last read `available` chapter per series id for a user, in one query.

  Public so the browse page can render Last-Reading meta without one query
  per card. Empty input short-circuits to avoid an `IN ()` query.
  """
  @spec last_read_chapters_for_user(integer(), [integer()]) :: %{integer() => Chapter.t()}
  def last_read_chapters_for_user(_user_id, []), do: %{}

  def last_read_chapters_for_user(user_id, series_ids)
      when is_integer(user_id) and is_list(series_ids) do
    from(p in ReadingProgress,
      where: p.user_id == ^user_id and p.series_id in ^series_ids,
      join: c in assoc(p, :last_chapter),
      where: c.status == "available",
      select: {p.series_id, c}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp parse_bookmark_status(%{"status" => status}) when status in @bookmark_statuses, do: status
  defp parse_bookmark_status(%{status: status}) when status in @bookmark_statuses, do: status
  defp parse_bookmark_status(_), do: nil

  defp parse_bookmark_sort(%{"sort_by" => sort}) when sort in @bookmark_sort_options, do: sort
  defp parse_bookmark_sort(%{sort_by: sort}) when sort in @bookmark_sort_options, do: sort
  # Legacy alias used by early UI drafts.
  defp parse_bookmark_sort(%{"sort" => sort}) when sort in @bookmark_sort_options, do: sort
  defp parse_bookmark_sort(_), do: "bookmarked_at"

  defp parse_bookmark_order(params, sort_by) do
    raw =
      case params do
        %{"order" => order} -> order
        %{order: order} -> order
        _ -> nil
      end

    cond do
      raw in @bookmark_orders -> raw
      sort_by == "title" -> "asc"
      true -> "desc"
    end
  end

  defp filter_bookmark_status(query, nil), do: query

  defp filter_bookmark_status(query, status) do
    where(query, [_b, s], s.publication_status == ^status)
  end

  defp order_bookmarks(query, "latest_update", "asc") do
    order_by(query, [b, s],
      asc_nulls_first: s.last_chapter_at,
      asc: b.inserted_at,
      asc: b.id
    )
  end

  defp order_bookmarks(query, "latest_update", _desc) do
    order_by(query, [b, s],
      desc_nulls_last: s.last_chapter_at,
      desc: b.inserted_at,
      desc: b.id
    )
  end

  defp order_bookmarks(query, "title", "desc") do
    order_by(query, [b, s], desc: s.title, desc: b.id)
  end

  defp order_bookmarks(query, "title", _asc) do
    order_by(query, [b, s], asc: s.title, asc: b.id)
  end

  defp order_bookmarks(query, _bookmarked_at, "asc") do
    order_by(query, [b, _s], asc: b.inserted_at, asc: b.id)
  end

  defp order_bookmarks(query, _bookmarked_at, _desc) do
    order_by(query, [b, _s], desc: b.inserted_at, desc: b.id)
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
