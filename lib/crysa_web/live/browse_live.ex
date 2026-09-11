defmodule CrysaWeb.Live.BrowseLive do
  @moduledoc """
  Series browse page — 1:1 with `ui-sketch/browser-page.pen`.

  Thin orchestration over `Crysa.Catalog`; all filtering,
  sorting, and pagination rules live in `Crysa.Catalog.Query`. This module only
  parses URL params, enriches rows for the cards, and handles LiveVue events.

  Sketch mapping (desktop frame + mobile frame):

    * Filter card — "Filter Genres" title + collapse chevron, divider, genre
      grid (3 columns desktop / 2 columns mobile) with tri-state tags
      (`?` neutral, green check include, red `x` exclude), divider, Reset +
      Search row, blue Active Filters bar with include/exclude counts.
    * Toolbar — right-aligned sort dropdown (`Last Updated` default).
    * Results — 5 cards per row on desktop; 2-column card grid on mobile.
      One unified card on all breakpoints: cover (250px, gradient fallback +
      `TRENDING` badge), bold title, 2-line description, views + rating pill,
      cyan `Read Chapter 1` CTA to the first available chapter.
    * Pagination — segmented `« 1 2 3 4 5 … 8 »` with a dark active segment.
    * Footer — `© 2025 Crysa …` line.

  Notes:

    * Public surface: `v-ssr={true}` (series grids are crawler content, per
      `plan.md` per-component guidance).
    * Header/footer chrome stays in the HEEX root layout; this island renders
      only the centered content column (`max-w-960`), matching the sketch's
      Browse Column. The sketch header is intentionally not ported.
    * The sketch shows no search box or status filter, but the previous page
      had both (`q`, `publication_status`). They are preserved in the toolbar
      so this port removes no query capability; the sort dropdown keeps all
      four backend sorts with sketch labels.
    * Default sort is `latest_updates` ("Last Updated") to match the sketch's
      first paint. Page size is fixed at 20 (5×4 desktop, 2×10 mobile).
    * Every filter interaction applies immediately via `push_patch`, so the URL
      stays shareable and the Active Bar never diverges from the results. The
      Search button re-syncs the URL and scrolls to the results.
    * `TRENDING` shows when `view_count >= 20_000` (the sketch's smallest
      example is 28,551 views).
    * The CTA targets chapter 1 (discovery intent: new visitors start at the
      beginning, never mid-story). Only the first chapter per series is
      fetched — one batched query per page, no per-card queries and no
      user-specific progress lookup on this public page.
  """

  use CrysaWeb, :live_view

  alias Crysa.Catalog

  @page_size 20
  @sort_options ~w(new most_viewed latest_updates title)
  @default_sort "latest_updates"
  @status_options ~w(ongoing completed hiatus discontinued)
  @trending_view_threshold 20_000

  on_mount {CrysaWeb.UserAuth, :mount_current_user}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="-mx-6 px-3 sm:px-4">
      <.vue
        v-component="BrowsePage"
        id="browse-page"
        v-ssr={true}
        entries={@entries}
        pagination={@pagination}
        categories={@categories}
        includeTags={@include_tags}
        excludeTags={@exclude_tags}
        query={@query}
        sort={@sort}
        pubStatus={@pub_status}
      />
    </div>
    """
  end

  @impl true
  def mount(params, _session, socket) do
    filters = parse_filters(params)

    {:ok,
     socket
     |> assign(
       query: filters.query,
       sort: filters.sort,
       pub_status: filters.pub_status,
       include_tags: filters.include_tags,
       exclude_tags: filters.exclude_tags,
       categories: list_category_json(),
       page_title: "Browse Series"
     )
     |> load_entries(filters)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = parse_filters(params)

    current = %{
      query: socket.assigns[:query],
      sort: socket.assigns[:sort],
      pub_status: socket.assigns[:pub_status],
      include_tags: socket.assigns[:include_tags],
      exclude_tags: socket.assigns[:exclude_tags],
      page: socket.assigns[:page]
    }

    next = %{
      query: filters.query,
      sort: filters.sort,
      pub_status: filters.pub_status,
      include_tags: filters.include_tags,
      exclude_tags: filters.exclude_tags,
      page: filters.page
    }

    if next == current do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(
         query: filters.query,
         sort: filters.sort,
         pub_status: filters.pub_status,
         include_tags: filters.include_tags,
         exclude_tags: filters.exclude_tags
       )
       |> load_entries(filters)}
    end
  end

  @impl true
  def handle_event("browse_search", %{"q" => q}, socket) do
    {:noreply, push_patch(socket, to: browse_url(socket, query: to_string(q || ""), page: 1))}
  end

  def handle_event("browse_search", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("browse_sort", %{"sort" => sort}, socket) do
    {:noreply, push_patch(socket, to: browse_url(socket, sort: sort, page: 1))}
  end

  def handle_event("browse_sort", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("browse_status", %{"status" => status}, socket) do
    {:noreply,
     push_patch(socket, to: browse_url(socket, pub_status: to_string(status || ""), page: 1))}
  end

  def handle_event("browse_status", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("browse_toggle_tag", %{"name" => name}, socket) when is_binary(name) do
    name = String.trim(name)

    if name == "" do
      {:noreply, socket}
    else
      {include, exclude} =
        cycle_tag(socket.assigns.include_tags, socket.assigns.exclude_tags, name)

      {:noreply,
       push_patch(socket,
         to: browse_url(socket, include_tags: include, exclude_tags: exclude, page: 1)
       )}
    end
  end

  def handle_event("browse_toggle_tag", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("browse_reset", _params, socket) do
    {:noreply,
     push_patch(socket, to: browse_url(socket, include_tags: [], exclude_tags: [], page: 1))}
  end

  @impl true
  def handle_event("browse_apply", _params, socket) do
    # Filter state already lives in the URL (every toggle patches
    # immediately), so apply only re-syncs the URL and lets the client scroll
    # to the results.
    {:noreply,
     push_patch(socket,
       to:
         browse_url(socket,
           query: socket.assigns.query,
           sort: socket.assigns.sort,
           pub_status: socket.assigns.pub_status,
           include_tags: socket.assigns.include_tags,
           exclude_tags: socket.assigns.exclude_tags,
           page: socket.assigns[:page] || 1
         )
     )}
  end

  @impl true
  def handle_event("browse_page", %{"page" => page_param}, socket) do
    {:noreply, push_patch(socket, to: browse_url(socket, page: parse_page(page_param)))}
  end

  def handle_event("browse_page", _params, socket), do: {:noreply, socket}

  # Filters

  defp parse_filters(params) do
    %{
      query: parse_query(params),
      sort: parse_sort(params["sort"]),
      pub_status: parse_status(params["publication_status"]),
      include_tags: parse_tag_list(params["category"]),
      exclude_tags: parse_tag_list(params["exclude_category"]),
      page: parse_page(params["page"])
    }
  end

  defp parse_query(%{"q" => q}) when is_binary(q) do
    q |> String.trim() |> String.slice(0, 100)
  end

  defp parse_query(_), do: ""

  defp parse_sort(sort) when sort in @sort_options, do: sort
  defp parse_sort(_), do: @default_sort

  defp parse_status(status) when status in @status_options, do: status
  defp parse_status(_), do: ""

  defp parse_tag_list(value) when is_binary(value), do: split_tags(value)
  defp parse_tag_list(values) when is_list(values), do: Enum.flat_map(values, &split_tags/1)
  defp parse_tag_list(_), do: []

  defp split_tags(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp split_tags(_), do: []

  defp parse_page(page) when is_integer(page) and page > 0, do: page

  defp parse_page(page) when is_binary(page) do
    case Integer.parse(page) do
      {int, ""} when int > 0 -> int
      _ -> 1
    end
  end

  defp parse_page(_), do: 1

  # `none -> include -> exclude -> none` per tap, matching the sketch's
  # `?` / green check / red `x` states.
  defp cycle_tag(include, exclude, name) do
    cond do
      name in include -> {List.delete(include, name), [name | exclude] |> Enum.uniq()}
      name in exclude -> {include, List.delete(exclude, name)}
      true -> {[name | include] |> Enum.uniq(), exclude}
    end
  end

  defp browse_url(socket, overrides) do
    base = %{
      query: socket.assigns[:query] || "",
      sort: socket.assigns[:sort] || @default_sort,
      pub_status: socket.assigns[:pub_status] || "",
      include_tags: socket.assigns[:include_tags] || [],
      exclude_tags: socket.assigns[:exclude_tags] || [],
      page: socket.assigns[:page] || 1
    }

    merged = Enum.into(overrides, base)

    # Fixed key order keeps URLs stable and readable; `URI.encode_query/1`
    # preserves list order.
    params =
      [
        {"q", merged.query, merged.query != ""},
        {"sort", merged.sort, merged.sort != @default_sort},
        {"publication_status", merged.pub_status, merged.pub_status != ""},
        {"category", Enum.join(merged.include_tags, ","), merged.include_tags != []},
        {"exclude_category", Enum.join(merged.exclude_tags, ","), merged.exclude_tags != []},
        {"page", to_string(merged.page), merged.page > 1}
      ]
      |> Enum.filter(fn {_key, _value, keep?} -> keep? end)
      |> Enum.map(fn {key, value, _} -> {key, value} end)

    case params do
      [] -> "/series"
      _ -> "/series?" <> URI.encode_query(params)
    end
  end

  # Loading

  defp load_entries(socket, filters) do
    query_params = %{
      "q" => filters.query,
      "sort" => filters.sort,
      "publication_status" => filters.pub_status,
      "category" => filters.include_tags,
      "exclude_category" => filters.exclude_tags,
      "page" => filters.page,
      "page_size" => @page_size
    }

    {series_list, pagination} = Catalog.browse_series(query_params)

    series_ids = Enum.map(series_list, & &1.id)
    first_by_id = Catalog.first_chapters_by_series(series_ids)

    assign(socket,
      entries: Enum.map(series_list, &to_entry_json(&1, first_by_id)),
      pagination: to_pagination_json(pagination),
      page: pagination.page
    )
  end

  defp list_category_json do
    Enum.map(Catalog.list_categories_with_counts(), fn {category, _count} ->
      %{id: category.id, name: category.name}
    end)
  end

  defp to_entry_json(series, first_by_id) do
    first = Map.get(first_by_id, series.id)

    %{
      id: series.id,
      title: series.title,
      slug: series.slug,
      description: series.description,
      coverUrl: Catalog.cover_url(series),
      viewCount: series.view_count || 0,
      ratingAverage: rating_average(series),
      ratingCount: series.rating_count || 0,
      trending: (series.view_count || 0) >= @trending_view_threshold,
      firstChapter: to_chapter_json(first)
    }
  end

  defp rating_average(%{rating_count: count, rating_sum: sum})
       when is_integer(count) and count > 0 and is_number(sum) do
    Float.round(sum / count, 1)
  end

  defp rating_average(_), do: nil

  defp to_chapter_json(nil), do: nil

  defp to_chapter_json(chapter) do
    %{
      displayNumber: chapter.display_number,
      chapterKey: chapter.chapter_key
    }
  end

  defp to_pagination_json(pagination) do
    %{
      page: pagination.page,
      pageSize: pagination.page_size,
      totalEntries: pagination.total_entries,
      totalPages: pagination.total_pages,
      hasPrevious: pagination.page > 1,
      hasNext: pagination.page < pagination.total_pages
    }
  end
end
