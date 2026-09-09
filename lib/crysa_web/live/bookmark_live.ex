defmodule CrysaWeb.Live.BookmarkLive do
  @moduledoc """
  User bookmark library page — 1:1 with `ui-sketch/bookmark-page.pen`.

  Thin orchestration over `Crysa.Library`; all filtering, sorting, and
  pagination rules live in `Crysa.Library.Query`. This module only maps
  server rows to island props and handles LiveVue events.

  Sketch mapping (desktop + mobile frames):

    * Title block — "Your Bookmarked Manga Library" + subtitle.
    * Toolbar — Download (client CSV export), Status filter, Sort By,
      Order. Rendered by the `BookmarkToolbar` island child.
    * Divider — 2px `$text-primary` (`#0F172A`).
    * Grid — 4 columns desktop / 2 columns mobile, card = cover (330px,
      gradient fallback + `NOT VIEWED` badge bar), title, relative time
      row, divider, Latest / Last Reading meta. Rendered by
      `BookmarkCard` children inside `BookmarkLibrary`.
    * Pagination — segmented `« 1 … 8 »` style, dark active segment.
    * Footer — `© 2025 Crysa …` line.

  Notes:

    * Private surface: `v-ssr={false}` (see `plan.md` per-component guidance;
      bookmarks are user-specific, not crawler content).
    * `Last Reading` comes from `user_reading_progress` (upserted on every
      chapter read); the island renders `—` when the user never opened a
      chapter and links directly to the reader otherwise, so reading can
      continue without opening the series page.
    * `hasUnread` drives the `NOT VIEWED` badge: true when the latest
      available chapter is newer than the last read chapter (or postdates
      the bookmark row when no progress exists yet).
  """

  use CrysaWeb, :live_view

  alias Crysa.Catalog
  alias Crysa.Library

  @page_size 12

  @status_options ~w(all ongoing completed hiatus discontinued)
  @sort_options ~w(latest_update bookmarked_at title)
  @order_options ~w(asc desc)

  on_mount {CrysaWeb.UserAuth, :mount_current_user}
  on_mount {CrysaWeb.UserAuth, :require_authenticated}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="-mx-6 px-3 sm:px-4">
      <.vue
        v-component="BookmarkLibrary"
        id="bookmark-library-page"
        v-ssr={false}
        entries={@entries}
        pagination={@pagination}
        status={@status}
        sortBy={@sort_by}
        order={@order}
        currentUser={@current_user_json}
      />
    </div>
    """
  end

  @impl true
  def mount(params, _session, socket) do
    user = socket.assigns.current_user
    filters = parse_filters(params)

    {:ok,
     socket
     |> assign(
       status: filters.status,
       sort_by: filters.sort_by,
       order: filters.order,
       current_user_json: to_user_json(user)
     )
     |> load_entries(user, filters)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    # `push_patch` from toolbar/pager flows through here so the URL stays
    # shareable; direct island pushes reload via the same path.
    filters = parse_filters(params)
    user = socket.assigns.current_user

    current = %{
      status: socket.assigns[:status],
      sort_by: socket.assigns[:sort_by],
      order: socket.assigns[:order],
      page: socket.assigns[:page]
    }

    next = %{
      status: filters.status,
      sort_by: filters.sort_by,
      order: filters.order,
      page: filters.page
    }

    if next == current do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(status: filters.status, sort_by: filters.sort_by, order: filters.order)
       |> load_entries(user, filters)}
    end
  end

  @impl true
  def handle_event("bookmarks_filter", params, socket) do
    filters = %{
      status: valid_status(params["status"] || socket.assigns.status),
      sort_by: valid_sort(params["sort_by"] || params["sortBy"] || socket.assigns.sort_by),
      order: valid_order(params["order"] || socket.assigns.order)
    }

    {:noreply,
     push_patch(socket,
       to:
         ~p"/bookmarks?status=#{filters.status}&sort_by=#{filters.sort_by}&order=#{filters.order}"
     )}
  end

  def handle_event("bookmarks_page", %{"page" => page_param}, socket) do
    page = parse_page_param(page_param)

    {:noreply,
     push_patch(socket,
       to:
         ~p"/bookmarks?status=#{socket.assigns.status}&sort_by=#{socket.assigns.sort_by}&order=#{socket.assigns.order}&page=#{page}"
     )}
  end

  def handle_event("bookmarks_page", _params, socket), do: {:noreply, socket}

  def handle_event("unbookmark", %{"id" => id_param}, socket) do
    user = socket.assigns.current_user

    with {series_id, ""} <- Integer.parse(to_string(id_param)),
         %{} = series <- Catalog.get_series(series_id) do
      case Library.unbookmark_series(user, series) do
        :ok ->
          filters = %{
            status: socket.assigns.status,
            sort_by: socket.assigns.sort_by,
            order: socket.assigns.order,
            page: socket.assigns[:page] || 1
          }

          {:noreply, load_entries(socket, user, filters)}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Could not remove bookmark. Please try again.")}
      end
    else
      _ -> {:noreply, put_flash(socket, :error, "Bookmark not found.")}
    end
  end

  def handle_event("unbookmark", _params, socket),
    do: {:noreply, put_flash(socket, :error, "Bookmark not found.")}

  # Reported by the island-mount safety net; mount already loads, so no-op.
  # The handler must exist because unhandled LiveVue events raise.
  def handle_event("bookmarks_opened", _params, socket), do: {:noreply, socket}

  defp load_entries(socket, user, filters) do
    {entries, pagination} =
      Library.list_user_bookmark_entries(user, %{
        "status" => filters.status,
        "sort_by" => filters.sort_by,
        "order" => filters.order,
        "page" => filters.page,
        "page_size" => @page_size
      })

    assign(socket,
      entries: Enum.map(entries, &to_entry_json/1),
      pagination: to_pagination_json(pagination),
      page: pagination.page
    )
  end

  defp parse_filters(params) do
    %{
      status: valid_status(params["status"]),
      sort_by: valid_sort(params["sort_by"] || params["sortBy"]),
      order: valid_order(params["order"]),
      page: parse_page_param(params["page"])
    }
  end

  defp valid_status(status) when status in @status_options, do: status
  defp valid_status(_), do: "all"

  defp valid_sort(sort) when sort in @sort_options, do: sort
  # Sketch default toolbar state is "Latest Update" + "Desc".
  defp valid_sort(_), do: "latest_update"

  defp valid_order(order) when order in @order_options, do: order
  defp valid_order(_), do: "desc"

  defp parse_page_param(param) do
    case Integer.parse(to_string(param || "1")) do
      {page, ""} when page > 0 -> page
      _ -> 1
    end
  end

  defp to_entry_json(%{
         bookmark: bookmark,
         series: series,
         latest_chapter: latest,
         last_read_chapter: last_read
       }) do
    %{
      id: series.id,
      title: series.title,
      slug: series.slug,
      coverUrl: Catalog.cover_url(series),
      status: series.publication_status || "ongoing",
      bookmarkedAt: bookmark.inserted_at && DateTime.to_iso8601(bookmark.inserted_at),
      lastChapterAt: series.last_chapter_at && DateTime.to_iso8601(series.last_chapter_at),
      updatedAt: series.updated_at && DateTime.to_iso8601(series.updated_at),
      latestChapter: to_chapter_json(latest),
      lastReading: to_chapter_json(last_read),
      hasUnread: has_unread?(bookmark, series, latest, last_read)
    }
  end

  # Backwards-compatible clause for callers still building entries
  # without progress data.
  defp to_entry_json(%{bookmark: _, series: _, latest_chapter: _} = entry) do
    to_entry_json(Map.put_new(entry, :last_read_chapter, nil))
  end

  defp to_chapter_json(nil), do: nil

  defp to_chapter_json(chapter) do
    %{
      displayNumber: chapter.display_number,
      chapterKey: chapter.chapter_key,
      publishedAt:
        (chapter.published_at || chapter.inserted_at) &&
          DateTime.to_iso8601(chapter.published_at || chapter.inserted_at)
    }
  end

  # Badge logic: with reading progress, the badge means the latest
  # available chapter is newer than what the user last opened (ordered by
  # `sort_key`, `id` tiebreak — the same order the reader uses). Without
  # progress, fall back to comparing against the bookmark row: anything
  # published after bookmarking counts as not viewed. Fixtures without
  # `published_at` fall back through inserted_at → series.last_chapter_at
  # so they stay deterministic.
  defp has_unread?(_bookmark, _series, nil, _last_read), do: false

  defp has_unread?(_bookmark, _series, latest, last_read) when not is_nil(last_read) do
    {latest.sort_key, latest.id} > {last_read.sort_key, last_read.id}
  end

  defp has_unread?(bookmark, series, latest, nil) do
    latest_time =
      latest.published_at || latest.inserted_at || series.last_chapter_at

    case {bookmark.inserted_at, latest_time} do
      {%DateTime{} = marked, %DateTime{} = fresh} ->
        DateTime.compare(fresh, marked) == :gt

      _ ->
        true
    end
  end

  defp to_user_json(nil), do: nil
  defp to_user_json(user), do: %{id: user.id, username: user.username}

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
