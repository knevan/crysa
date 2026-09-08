defmodule CrysaWeb.Live.NotificationFeed do
  @moduledoc """
  Shared feed state for notification surfaces.

  Both the notification bell dropdown (`NotificationBellLive`) and the
  full-page center (`NotificationsLive`) keep the same assigns shape and
  the same transition semantics; only their chrome and navigation differ.
  All functions take and return a socket and never touch the database
  outside `Crysa.Notifications`.
  """

  import Phoenix.Component, only: [assign: 2]

  alias Crysa.Notifications

  @page_size 20

  @doc "Default page size for panel fetches."
  @spec page_size() :: pos_integer()
  def page_size, do: @page_size

  @doc "Normalizes a tab name coming from params or client events."
  @spec valid_tab(term()) :: String.t()
  def valid_tab(tab) when tab in ["comment", "series"], do: tab
  def valid_tab(_), do: "comment"

  @doc "Maps a notification action to its panel tab."
  @spec tab_for_action(term()) :: String.t()
  def tab_for_action("series_chapter"), do: "series"
  def tab_for_action("comment_" <> _), do: "comment"
  def tab_for_action(_), do: "comment"

  @doc "Minimal JSON-safe user projection for island props."
  @spec to_user_json(map() | nil) :: map() | nil
  def to_user_json(nil), do: nil
  def to_user_json(user), do: %{id: user.id, username: user.username}

  @doc """
  Loads the first page of `tab` and resets paging state.

  Options (per surface):

    * `:limit` — page size, defaults to `page_size/0`. The header
      dropdown uses a small preview window.
    * `:unread_only` — when true, read rows are excluded so marking
      read clears them from the surface instead of greying them out.

  Also assigns numbered-pagination state (`page: 1`, `total_pages`)
  from a matching count query, so the full-page center can render a
  pager without a second roundtrip. The dropdown ignores those assigns
  (it caps at its preview window and never pages).
  Also flags the feed as loaded: dropdown visibility is client-side
  (`JS.toggle`), so `loaded` — not visibility — decides whether list
  queries run. Every caller reaches this only through an explicit
  open/tab event or the island-mount safety net.
  """
  @spec load_first_page(Phoenix.LiveView.Socket.t(), integer(), String.t(), keyword()) ::
          Phoenix.LiveView.Socket.t()
  def load_first_page(socket, user_id, tab, opts \\ []) do
    limit = page_limit(opts)
    total_pages = total_pages(user_id, tab, limit, opts)

    {:ok, {items, has_more}} =
      Notifications.list_notifications(user_id, tab,
        limit: limit,
        unread_only: Keyword.get(opts, :unread_only, false)
      )

    last = List.last(items)

    socket
    |> assign(
      items: items,
      has_more: has_more,
      cursor: last && last.id,
      page: 1,
      total_pages: total_pages,
      paged: false,
      loaded: true
    )
    |> load_counts(user_id)
  end

  @doc """
  Loads numbered `page` of `tab`, replacing the current list.

  Page numbers are clamped into `1..total_pages`, so out-of-range
  client input (stale pager, hand-crafted events) lands on the nearest
  valid page instead of an empty list. `paged` mirrors `page > 1` so
  realtime arrivals keep skipping list reloads once the user leaves
  the first page, exactly like the old append cursor did.
  """
  @spec load_page(Phoenix.LiveView.Socket.t(), integer(), String.t(), term(), keyword()) ::
          Phoenix.LiveView.Socket.t()
  def load_page(socket, user_id, tab, page_param, opts \\ []) do
    limit = page_limit(opts)
    total = total_pages(user_id, tab, limit, opts)
    page = clamp_page(page_param, total)

    {:ok, {items, has_more}} =
      Notifications.list_notifications(user_id, tab,
        limit: limit,
        offset: (page - 1) * limit,
        unread_only: Keyword.get(opts, :unread_only, false)
      )

    last = List.last(items)

    socket
    |> assign(
      items: items,
      has_more: has_more,
      cursor: last && last.id,
      page: page,
      total_pages: total,
      paged: page > 1,
      loaded: true
    )
    |> load_counts(user_id)
  end

  @doc """
  Loads the first page unless already loaded. Idempotent by design:
  the bell button and the island-mount safety net both report "shown"
  and neither may trigger duplicate fetches.
  """
  @spec ensure_loaded(Phoenix.LiveView.Socket.t(), integer(), String.t(), keyword()) ::
          Phoenix.LiveView.Socket.t()
  def ensure_loaded(socket, user_id, tab, opts \\ [])
  def ensure_loaded(%{assigns: %{loaded: true}} = socket, _user_id, _tab, _opts), do: socket
  def ensure_loaded(socket, user_id, tab, opts), do: load_first_page(socket, user_id, tab, opts)

  @doc "Refreshes unread counts from source of truth."
  @spec load_counts(Phoenix.LiveView.Socket.t(), integer()) :: Phoenix.LiveView.Socket.t()
  def load_counts(socket, user_id) do
    assign(socket, unread_counts: counts_json(Notifications.unread_counts(user_id)))
  end

  @doc "Appends the next keyset page; leaves the socket untouched on bad cursors."
  @spec append_page(Phoenix.LiveView.Socket.t(), integer(), String.t(), term(), keyword()) ::
          {:ok, Phoenix.LiveView.Socket.t()} | {:error, Phoenix.LiveView.Socket.t()}
  def append_page(socket, user_id, tab, cursor_param, opts \\ []) do
    with {cursor, ""} <- Integer.parse(to_string(cursor_param)),
         {:ok, {more, has_more}} <-
           Notifications.list_notifications(user_id, tab,
             limit: Keyword.get(opts, :limit, @page_size),
             cursor: cursor,
             unread_only: Keyword.get(opts, :unread_only, false)
           ) do
      merged = socket.assigns.items ++ more
      last = List.last(merged)

      {:ok,
       assign(socket,
         items: merged,
         has_more: has_more,
         cursor: last && last.id,
         paged: true
       )}
    else
      _ -> {:error, socket}
    end
  end

  @doc """
  Marks one row read; reports `:not_found` for foreign ids.

  With `remove: true` the row is dropped from the local list (dropdown
  surfaces show unread only); otherwise it is stamped in place so
  history surfaces keep it greyed out.
  """
  @spec mark_item(Phoenix.LiveView.Socket.t(), integer(), term(), keyword()) ::
          {:ok, Phoenix.LiveView.Socket.t()} | {:error, :not_found}
  def mark_item(socket, user_id, id_param, opts \\ []) do
    with {id, ""} <- Integer.parse(to_string(id_param)),
         {:ok, _} <- Notifications.mark_as_read(user_id, %{scope: "item", id: id}) do
      items = apply_mark_local(socket.assigns.items, id, Keyword.get(opts, :remove, false))
      {:ok, socket |> assign(items: items) |> load_counts(user_id)}
    else
      _ -> {:error, :not_found}
    end
  end

  defp apply_mark_local(items, id, true), do: Enum.reject(items, &(&1.id == id))

  defp apply_mark_local(items, id, false) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    Enum.map(items, fn
      %{id: ^id} = item -> %{item | read_at: now}
      item -> item
    end)
  end

  @doc "Marks the whole active tab read and reloads its first page."
  @spec mark_tab(Phoenix.LiveView.Socket.t(), integer(), String.t(), keyword()) ::
          Phoenix.LiveView.Socket.t()
  def mark_tab(socket, user_id, tab, opts \\ []) do
    case Notifications.mark_as_read(user_id, %{scope: "tab", tab: tab}) do
      {:ok, _} -> load_first_page(socket, user_id, tab, opts)
      {:error, _} -> socket
    end
  end

  @doc """
  Handles a realtime arrival: always refresh counts; reload the list only
  when the feed was opened before (`loaded`), watches the first page of
  the matching tab, and has not paged deeper. Surfaces without a loaded
  feed (bell never opened) pay counts only, never list queries.
  """
  @spec refresh_on_created(Phoenix.LiveView.Socket.t(), integer(), term(), keyword()) ::
          Phoenix.LiveView.Socket.t()
  def refresh_on_created(socket, user_id, action, opts \\ []) do
    socket = load_counts(socket, user_id)

    if socket.assigns[:loaded] == true and
         tab_for_action(action) == socket.assigns.active_tab and
         not socket.assigns.paged do
      load_first_page(socket, user_id, socket.assigns.active_tab, opts)
    else
      socket
    end
  end

  defp counts_json(%{comment: comment, series: series}),
    do: %{comment: comment, series: series, total: comment + series}

  defp page_limit(opts) do
    case Keyword.get(opts, :limit, @page_size) do
      limit when is_integer(limit) and limit > 0 -> limit
      _ -> @page_size
    end
  end

  defp total_pages(user_id, tab, limit, opts) do
    total =
      case Notifications.count_notifications(user_id, tab,
             unread_only: Keyword.get(opts, :unread_only, false)
           ) do
        {:error, _} -> 0
        count -> count
      end

    max(1, ceil_div(total, max(limit, 1)))
  end

  defp ceil_div(total, limit), do: div(total + limit - 1, limit)

  defp clamp_page(param, total_pages) do
    page =
      case Integer.parse(to_string(param)) do
        {n, ""} -> n
        _ -> 1
      end

    page |> max(1) |> min(total_pages)
  end
end
