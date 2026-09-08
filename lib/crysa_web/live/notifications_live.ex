defmodule CrysaWeb.Live.NotificationsLive do
  @moduledoc """
  Notification center page hosting the `NotificationPanel` LiveVue island.

  Feed state transitions live in `CrysaWeb.Live.NotificationFeed`, shared
  with the header bell dropdown; this module only owns page chrome and
  tab navigation through the URL.
  """

  use CrysaWeb, :live_view

  alias CrysaWeb.Live.NotificationFeed

  on_mount {CrysaWeb.UserAuth, :mount_current_user}
  on_mount {CrysaWeb.UserAuth, :require_authenticated}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="-mx-6 px-3 sm:px-4">
      <.vue
        v-component="NotificationPanel"
        id="notification-panel-page"
        v-ssr={false}
        items={@items}
        hasMore={@has_more}
        cursor={@cursor}
        activeTab={@active_tab}
        unread={@unread_counts}
        currentUser={@current_user_json}
        showViewAll={false}
        page={@page}
        totalPages={@total_pages}
      />
    </div>
    """
  end

  @impl true
  def mount(params, _session, socket) do
    user = socket.assigns.current_user
    tab = NotificationFeed.valid_tab(params["tab"])

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Crysa.PubSub, "notifications:#{user.id}")
    end

    {:ok,
     socket
     |> assign(
       active_tab: tab,
       current_user_json: NotificationFeed.to_user_json(user)
     )
     |> NotificationFeed.load_first_page(user.id, tab)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tab = NotificationFeed.valid_tab(params["tab"])

    if tab == socket.assigns.active_tab do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(active_tab: tab)
       |> NotificationFeed.load_first_page(current_user_id(socket), tab)}
    end
  end

  @impl true
  def handle_event("notifications_tab", %{"tab" => tab}, socket) do
    {:noreply, push_patch(socket, to: ~p"/notifications?tab=#{NotificationFeed.valid_tab(tab)}")}
  end

  # Reported by the island-mount safety net; no-op here since mount
  # already loads, but the handler must exist (unhandled events raise).
  def handle_event("notifications_opened", _params, socket) do
    {:noreply,
     NotificationFeed.ensure_loaded(
       socket,
       current_user_id(socket),
       socket.assigns.active_tab
     )}
  end

  def handle_event("notifications_more", %{"cursor" => cursor}, socket) do
    %{active_tab: tab} = socket.assigns

    case NotificationFeed.append_page(socket, current_user_id(socket), tab, cursor) do
      {:ok, socket} -> {:noreply, socket}
      {:error, socket} -> {:noreply, socket}
    end
  end

  # Numbered pager for the full-page center: replaces the list instead
  # of appending, so each page is a stable 20-row window. Out-of-range
  # input is clamped server-side in `NotificationFeed.load_page/5`.
  def handle_event("notifications_page", %{"page" => page}, socket) do
    {:noreply,
     NotificationFeed.load_page(socket, current_user_id(socket), socket.assigns.active_tab, page)}
  end

  def handle_event("notifications_page", _params, socket), do: {:noreply, socket}

  def handle_event("notifications_mark_read", %{"scope" => "item", "id" => id}, socket) do
    case NotificationFeed.mark_item(socket, current_user_id(socket), id) do
      {:ok, socket} -> {:noreply, socket}
      {:error, _} -> {:noreply, socket}
    end
  end

  def handle_event("notifications_mark_read", %{"scope" => "tab"}, socket) do
    {:noreply,
     NotificationFeed.mark_tab(socket, current_user_id(socket), socket.assigns.active_tab)}
  end

  def handle_event("notifications_mark_read", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:notification_created, %{action: action}}, socket) do
    {:noreply, NotificationFeed.refresh_on_created(socket, current_user_id(socket), action)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp current_user_id(socket), do: socket.assigns.current_user.id
end
