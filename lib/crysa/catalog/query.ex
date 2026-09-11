defmodule Crysa.Catalog.Query do
  @moduledoc """
  Read-model queries for the Catalog context.

  Builds composable, parameterized Ecto queries for series browsing,
  searching, sorting, and bounded pagination. All user-provided input is
  parsed and validated before it reaches the database; search terms are
  escaped so `LIKE` wildcards in user input are treated literally.
  """

  import Ecto.Query

  alias Crysa.Catalog
  alias Crysa.Catalog.{Category, Chapter, ChapterImage, Normalization, Series}
  alias Crysa.Pagination
  alias Crysa.Repo

  @default_page_size 24
  @max_page_size 60
  @default_chapter_page_size 50
  @max_chapter_page_size 100
  @max_search_length 100
  @admin_default_page_size 25
  @admin_max_page_size 100

  @sort_options ~w(new most_viewed latest_updates title)
  @publication_statuses Catalog.publication_statuses()
  @chapter_statuses Catalog.chapter_statuses()

  @spec browse_series(map()) :: {[Series.t()], Pagination.t()}
  def browse_series(params) when is_map(params) do
    filters = parse_filters(params)
    page = parse_page(params)
    page_size = parse_page_size(params)

    base =
      from(s in Series, as: :series)
      |> where([s], is_nil(s.archived_at))
      |> filter_series(filters)
      |> order_series(filters)

    total = Repo.aggregate(base, :count, :id)
    page = clamp_page(page, page_size, total)

    series =
      base
      |> limit(^page_size)
      |> offset(^((page - 1) * page_size))
      |> Repo.all()

    {series, Pagination.build(page, page_size, total)}
  end

  @spec list_new_series(map()) :: {[Series.t()], Pagination.t()}
  def list_new_series(params \\ %{}), do: browse_series(Map.put(params, "sort", "new"))

  @spec list_most_viewed(map()) :: {[Series.t()], Pagination.t()}
  def list_most_viewed(params \\ %{}), do: browse_series(Map.put(params, "sort", "most_viewed"))

  @spec list_latest_updates(map()) :: {[Series.t()], Pagination.t()}
  def list_latest_updates(params \\ %{}),
    do: browse_series(Map.put(params, "sort", "latest_updates"))

  @spec list_chapters(integer(), map()) :: {[Chapter.t()], Pagination.t()}
  def list_chapters(series_id, params \\ %{}) when is_integer(series_id) do
    page = parse_page(params)
    page_size = parse_page_size(params, @default_chapter_page_size, @max_chapter_page_size)
    search = parse_search(params)
    sort = parse_chapter_sort(params)
    status = parse_chapter_status(params)

    base =
      from(c in Chapter, where: c.series_id == ^series_id)
      |> filter_chapters_status(status)
      |> filter_chapters_search(search)
      |> order_chapters(sort)

    total = Repo.aggregate(base, :count, :id)
    page = clamp_page(page, page_size, total)

    chapters =
      base
      |> limit(^page_size)
      |> offset(^((page - 1) * page_size))
      |> Repo.all()

    {chapters, Pagination.build(page, page_size, total)}
  end

  defp parse_chapter_sort(%{"sort" => sort}) when sort in ~w(newest oldest) do
    case sort do
      "oldest" -> :oldest
      _ -> :newest
    end
  end

  defp parse_chapter_sort(_), do: :newest

  # Visibility gate input: only exact known statuses pass; anything else
  # (including user-supplied values) means "no status filter". Public
  # call sites must force "available" server-side, never from user params.
  defp parse_chapter_status(%{"status" => status}) when status in @chapter_statuses,
    do: status

  defp parse_chapter_status(_), do: nil

  defp filter_chapters_status(query, nil), do: query

  defp filter_chapters_status(query, status) do
    where(query, [c], c.status == ^status)
  end

  defp filter_chapters_search(query, nil), do: query

  defp filter_chapters_search(query, term) do
    pattern = "%#{escape_like(term)}%"

    where(
      query,
      [c],
      ilike(c.display_number, ^pattern) or ilike(c.title, ^pattern) or
        ilike(c.chapter_key, ^pattern)
    )
  end

  defp order_chapters(query, :oldest), do: order_by(query, [c], asc: c.sort_key, asc: c.id)
  defp order_chapters(query, :newest), do: order_by(query, [c], desc: c.sort_key, desc: c.id)

  @spec list_categories_with_counts() :: [{Category.t(), non_neg_integer()}]
  def list_categories_with_counts do
    from(c in Category,
      join: sc in "series_categories",
      on: sc.category_id == c.id,
      join: s in Series,
      on: s.id == sc.series_id and is_nil(s.archived_at),
      group_by: c.id,
      having: count(s.id) > 0,
      order_by: [asc: c.name],
      select: {c, count(s.id)}
    )
    |> Repo.all()
  end

  @spec get_series_by_slug(String.t()) :: Series.t() | nil
  def get_series_by_slug(slug) when is_binary(slug) do
    from(s in Series,
      where: s.slug == ^slug and is_nil(s.archived_at),
      preload: [:categories, :authors],
      limit: 1
    )
    |> Repo.one()
  end

  @doc "Admin variant that returns archived series as well."
  @spec get_series_by_slug_admin(String.t()) :: Series.t() | nil
  def get_series_by_slug_admin(slug) when is_binary(slug) do
    from(s in Series,
      where: s.slug == ^slug,
      preload: [:categories, :authors],
      limit: 1
    )
    |> Repo.one()
  end

  @spec get_latest_chapter(integer()) :: Chapter.t() | nil
  def get_latest_chapter(series_id) when is_integer(series_id) do
    from(c in Chapter,
      where: c.series_id == ^series_id and c.status == "available",
      order_by: [desc: c.sort_key, desc: c.id],
      limit: 1
    )
    |> Repo.one()
  end

  @doc """
  Latest `available` chapter per series id in a single query.

  Uses Postgres `DISTINCT ON (series_id)` ordered by `sort_key DESC, id DESC`,
  mirroring `get_latest_chapter/1`. Empty input short-circuits to avoid an
  `IN ()` query. Used by the browse page to render Latest/Last-Reading meta
  without one query per card.
  """
  @spec latest_chapters_by_series([integer()]) :: %{integer() => Chapter.t()}
  def latest_chapters_by_series([]), do: %{}

  def latest_chapters_by_series(series_ids) when is_list(series_ids) do
    from(c in Chapter,
      where: c.series_id in ^series_ids and c.status == "available",
      distinct: c.series_id,
      order_by: [asc: c.series_id, desc: c.sort_key, desc: c.id]
    )
    |> Repo.all()
    |> Map.new(fn chapter -> {chapter.series_id, chapter} end)
  end

  @doc """
  First `available` chapter per series id in a single query.

  Browse cards link their CTA to chapter 1 (discovery intent), so the
  first chapter — not the latest — is the only per-card chapter needed.
  Empty input short-circuits to avoid an `IN ()` query.
  """
  @spec first_chapters_by_series([integer()]) :: %{integer() => Chapter.t()}
  def first_chapters_by_series([]), do: %{}

  def first_chapters_by_series(series_ids) when is_list(series_ids) do
    from(c in Chapter,
      where: c.series_id in ^series_ids and c.status == "available",
      distinct: c.series_id,
      order_by: [asc: c.series_id, asc: c.sort_key, asc: c.id]
    )
    |> Repo.all()
    |> Map.new(fn chapter -> {chapter.series_id, chapter} end)
  end

  @spec get_reader_chapter(integer(), String.t()) :: Chapter.t() | nil
  def get_reader_chapter(series_id, chapter_key) when is_integer(series_id) do
    images_query = from(i in ChapterImage, order_by: i.image_order)

    from(c in Chapter,
      where:
        c.series_id == ^series_id and c.chapter_key == ^chapter_key and
          c.status == "available",
      preload: [images: ^images_query],
      limit: 1
    )
    |> Repo.one()
  end

  @doc """
  Admin series table listing with search and bounded pagination.

  Designed for the TanStack-backed admin data grid: server-side pagination
  with client-side rendering. Search is filtered via `ILIKE` on `title` and
  `slug` (wildcard-escaped), ordering is stable `updated_at DESC, id DESC`
  for the `Last Updated` column. Authors are preloaded for the `Authors`
  column. Page size defaults to 25 (matching the admin UI) and is clamped to
  `1..50` to bound offsets and payload size.
  """
  @spec admin_list_series(map()) :: {[Series.t()], Pagination.t()}
  def admin_list_series(params \\ %{}) when is_map(params) do
    q = parse_search(params)
    page = parse_page(params)
    page_size = parse_page_size(params, @admin_default_page_size, @admin_max_page_size)

    base =
      from(s in Series, as: :series)
      |> filter_admin_search(q)
      |> order_by([s], desc: s.updated_at, desc: s.id)

    total = Repo.aggregate(base, :count, :id)
    page = clamp_page(page, page_size, total)

    series =
      base
      |> preload([:authors])
      |> limit(^page_size)
      |> offset(^((page - 1) * page_size))
      |> Repo.all()

    {series, Pagination.build(page, page_size, total)}
  end

  defp filter_admin_search(query, nil), do: query

  defp filter_admin_search(query, term) do
    pattern = "%#{escape_like(term)}%"
    where(query, [s], ilike(s.title, ^pattern) or ilike(s.slug, ^pattern))
  end

  @spec chapter_navigation(integer(), String.t()) :: {map() | nil, map() | nil}
  def chapter_navigation(series_id, chapter_key) when is_integer(series_id) do
    case chapter_position(series_id, chapter_key) do
      nil ->
        {nil, nil}

      %{sort_key: sort_key, id: id} ->
        previous = nearby_chapter(series_id, sort_key, id, :previous)
        next = nearby_chapter(series_id, sort_key, id, :next)
        {previous, next}
    end
  end

  defp chapter_position(series_id, chapter_key) do
    from(c in Chapter,
      where:
        c.series_id == ^series_id and c.chapter_key == ^chapter_key and
          c.status == "available",
      select: %{sort_key: c.sort_key, id: c.id},
      limit: 1
    )
    |> Repo.one()
  end

  defp nearby_chapter(series_id, sort_key, id, :previous) do
    from(c in Chapter,
      where:
        c.series_id == ^series_id and c.status == "available" and
          (c.sort_key < ^sort_key or (c.sort_key == ^sort_key and c.id < ^id)),
      order_by: [desc: c.sort_key, desc: c.id],
      select: %{chapter_key: c.chapter_key, display_number: c.display_number},
      limit: 1
    )
    |> Repo.one()
  end

  defp nearby_chapter(series_id, sort_key, id, :next) do
    from(c in Chapter,
      where:
        c.series_id == ^series_id and c.status == "available" and
          (c.sort_key > ^sort_key or (c.sort_key == ^sort_key and c.id > ^id)),
      order_by: [asc: c.sort_key, asc: c.id],
      select: %{chapter_key: c.chapter_key, display_number: c.display_number},
      limit: 1
    )
    |> Repo.one()
  end

  @spec escape_like(String.t()) :: String.t()
  def escape_like(term) when is_binary(term) do
    term
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  defp parse_filters(params) do
    %{
      q: parse_search(params),
      categories: parse_category_names(params, "category"),
      exclude_categories: parse_category_names(params, "exclude_category"),
      publication_status: parse_status(params),
      sort: parse_sort(params)
    }
  end

  defp parse_search(%{"q" => q}) when is_binary(q) do
    case q |> String.trim() |> String.slice(0, @max_search_length) do
      "" -> nil
      term -> term
    end
  end

  defp parse_search(_), do: nil

  defp parse_category_names(params, key) do
    case params[key] do
      value when is_binary(value) -> split_category_names(value)
      values when is_list(values) -> Enum.flat_map(values, &split_category_names/1)
      _ -> []
    end
    |> Enum.uniq()
  end

  defp split_category_names(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&Normalization.normalized_name/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp split_category_names(_), do: []

  defp parse_status(%{"publication_status" => status}) when status in @publication_statuses,
    do: status

  defp parse_status(_), do: nil

  defp parse_sort(%{"sort" => sort}) when sort in @sort_options, do: sort
  defp parse_sort(_), do: "new"

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

  defp filter_series(query, filters) do
    query
    |> filter_search(filters.q)
    |> filter_categories(filters.categories)
    |> filter_excluded_categories(filters.exclude_categories)
    |> filter_status(filters.publication_status)
  end

  defp filter_search(query, nil), do: query

  defp filter_search(query, term) do
    where(query, [s], ilike(s.title, ^"%#{escape_like(term)}%"))
  end

  defp filter_categories(query, []), do: query

  defp filter_categories(query, names) do
    where(
      query,
      [s],
      exists(
        from sc in "series_categories",
          join: c in "categories",
          on: c.id == sc.category_id,
          where: sc.series_id == parent_as(:series).id and c.normalized_name in ^names,
          select: sc.series_id
      )
    )
  end

  defp filter_excluded_categories(query, []), do: query

  defp filter_excluded_categories(query, names) do
    where(
      query,
      [s],
      not exists(
        from sc in "series_categories",
          join: c in "categories",
          on: c.id == sc.category_id,
          where: sc.series_id == parent_as(:series).id and c.normalized_name in ^names,
          select: sc.series_id
      )
    )
  end

  defp filter_status(query, nil), do: query

  defp filter_status(query, status) do
    where(query, [s], s.publication_status == ^status)
  end

  # Search results are ranked by pg_trgm similarity; browse results use
  # the requested sort. The primary key always acts as a stable tie-breaker.
  defp order_series(query, %{q: q, sort: _sort}) when is_binary(q) do
    order_by(query, [s], desc: fragment("similarity(?, ?)", s.title, ^q), desc: s.id)
  end

  defp order_series(query, %{q: nil, sort: "new"}) do
    order_by(query, [s], desc: s.inserted_at, desc: s.id)
  end

  defp order_series(query, %{q: nil, sort: "most_viewed"}) do
    order_by(query, [s], desc: s.view_count, desc: s.id)
  end

  defp order_series(query, %{q: nil, sort: "latest_updates"}) do
    order_by(query, [s], desc_nulls_last: s.last_chapter_at, desc: s.id)
  end

  defp order_series(query, %{q: nil, sort: "title"}) do
    order_by(query, [s], asc: s.title, asc: s.id)
  end
end
