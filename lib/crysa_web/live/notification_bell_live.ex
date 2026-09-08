defmodule CrysaWeb.Live.NotificationBellLive do
  @moduledoc """
  Header notification bell with a same-page dropdown panel.

  Rendered once per page from the root layout through `live_render`
  (`sticky: true`), so the bell and its dropdown work on every page —
  dead controller pages included — without navigation. Feed state
  transitions are shared with the full-page center through
  `CrysaWeb.Live.NotificationFeed`.

  Split-brain design, and why: dropdown *visibility* is purely
  client-side (`JS.toggle`/`JS.hide`), so the button responds instantly
  even before the socket connects — a server roundtrip toggle would
  silently drop first clicks made during the post-navigation dead
  window. The server owns *data* only. To make that bulletproof the
  5-newest-unread preview loads eagerly on mount (dead render
  included): the dropdown can never enter a loading state, at the cost
  of one small bounded query per page view for logged-in users.
  """

  use CrysaWeb, :live_view

  alias Crysa.Accounts
  alias CrysaWeb.Live.NotificationFeed

  # Dropdown preview window: newest unread only, capped so the panel
  # never stretches the viewport. Older entries live behind "View all".
  @feed_opts [limit: 5, unread_only: true]

  @impl true
  def render(%{current_user: nil} = assigns) do
    ~H"""
    <span class="hidden" aria-hidden="true"></span>
    """
  end

  def render(assigns) do
    ~H"""
    <div class="relative" phx-click-away={JS.hide(to: "#notif-dropdown")}>
      <button
        type="button"
        phx-click={JS.toggle(to: "#notif-dropdown") |> JS.push("notifications_opened")}
        class="btn btn-ghost btn-circle relative"
        aria-label="Notifications"
      >
        <.icon name="hero-bell" class="h-5 w-5" />
        <span
          :if={@unread_counts.total > 0}
          class="absolute right-1 top-1 flex h-4 min-w-4 items-center justify-center rounded-full bg-error px-1 text-[10px] font-bold text-white"
        >
          {if @unread_counts.total > 99, do: "99+", else: @unread_counts.total}
        </span>
      </button>
      <div
        id="notif-dropdown"
        class="hidden fixed inset-x-2 top-17 z-50 max-h-[calc(100vh-84px)] overflow-y-auto sm:absolute sm:inset-x-auto sm:left-auto sm:right-0 sm:top-full sm:mt-2 sm:w-95 sm:max-h-[75vh]"
      >
        <.vue
          v-component="NotificationPanel"
          id="notification-panel-dropdown"
          v-ssr={false}
          items={@items}
          hasMore={@has_more}
          cursor={@cursor}
          activeTab={@active_tab}
          unread={@unread_counts}
          currentUser={@current_user_json}
          showViewAll={true}
          showLoadMore={false}
        />
      </div>
    </div>
    """
  end

  @impl true
  def mount(_params, session, socket) do
    user =
      if token = session["user_token"] do
        Accounts.get_user_by_session_token(token)
      end

    socket =
      assign(socket,
        current_user: user,
        current_user_json: NotificationFeed.to_user_json(user),
        active_tab: "comment",
        items: [],
        has_more: false,
        cursor: nil,
        paged: false,
        loaded: false,
        unread_counts: %{comment: 0, series: 0, total: 0}
      )

    socket =
      if user do
        # Preview feed loads eagerly (dead render included): 5 newest
        # unread rows keep every page view cheap while guaranteeing the
        # dropdown can never enter a loading state it cannot leave.
        socket = NotificationFeed.load_first_page(socket, user.id, "comment", @feed_opts)

        if connected?(socket) do
          Phoenix.PubSub.subscribe(Crysa.PubSub, "notifications:#{user.id}")
        end

        socket
      else
        socket
      end

    {:ok, socket, layout: false}
  end

  @impl true
  def handle_event("notifications_opened", _params, %{assigns: %{current_user: nil}} = socket) do
    {:noreply, socket}
  end

  # Reported by the bell button (after its instant client-side toggle)
  # and by the island-mount safety net. Idempotent: repeated reports
  # never refetch.
  def handle_event("notifications_opened", _params, socket) do
    {:noreply,
     NotificationFeed.ensure_loaded(
       socket,
       current_user_id(socket),
       socket.assigns.active_tab
     )}
  end

  def handle_event("notifications_tab", %{"tab" => tab}, socket) do
    tab = NotificationFeed.valid_tab(tab)

    {:noreply,
     socket
     |> assign(active_tab: tab)
     |> NotificationFeed.load_first_page(current_user_id(socket), tab, @feed_opts)}
  end

  def handle_event("notifications_more", %{"cursor" => cursor}, socket) do
    %{active_tab: tab} = socket.assigns

    case NotificationFeed.append_page(socket, current_user_id(socket), tab, cursor, @feed_opts) do
      {:ok, socket} -> {:noreply, socket}
      {:error, socket} -> {:noreply, socket}
    end
  end

  def handle_event("notifications_mark_read", %{"scope" => "item", "id" => id}, socket) do
    case NotificationFeed.mark_item(socket, current_user_id(socket), id, remove: true) do
      {:ok, socket} -> {:noreply, socket}
      {:error, _} -> {:noreply, socket}
    end
  end

  def handle_event("notifications_mark_read", %{"scope" => "tab"}, socket) do
    {:noreply,
     NotificationFeed.mark_tab(
       socket,
       current_user_id(socket),
       socket.assigns.active_tab,
       @feed_opts
     )}
  end

  def handle_event("notifications_mark_read", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info(
        {:notification_created, %{action: _action}},
        %{assigns: %{current_user: nil}} = socket
      ) do
    {:noreply, socket}
  end

  def handle_info({:notification_created, %{action: action}}, socket) do
    {:noreply,
     NotificationFeed.refresh_on_created(socket, current_user_id(socket), action, @feed_opts)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp current_user_id(socket), do: socket.assigns.current_user.id
end
