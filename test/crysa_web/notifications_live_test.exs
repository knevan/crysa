defmodule CrysaWeb.NotificationsLiveTest do
  use CrysaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Crysa.Accounts
  alias Crysa.AccountsFixtures
  alias Crysa.CatalogFixtures
  alias Crysa.Comments
  alias Crysa.Library
  alias Crysa.Notifications

  describe "GET /notifications" do
    test "redirects guests to login", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/auth/login"}}} = live(conn, ~p"/notifications")
    end

    test "renders the panel island with tabs and unread counts", %{conn: conn} do
      user = AccountsFixtures.user_fixture()
      other = AccountsFixtures.user_fixture()
      series = CatalogFixtures.series_fixture()
      chapter = CatalogFixtures.chapter_fixture(series)

      {:ok, comment} =
        Comments.create_comment(%{
          user_id: user.id,
          series_id: series.id,
          body_markdown: "my comment"
        })

      assert {:ok, _} = Comments.vote_comment(other, comment, 1)
      assert {:ok, _} = Library.bookmark_series(other, series)
      assert {:ok, 1} = Notifications.notify_series_chapter(series.id, chapter.id)

      {:ok, view, _html} = conn |> log_in(user) |> live(~p"/notifications")

      vue = LiveVue.Test.get_vue(view)
      assert vue.component == "NotificationPanel"
      assert vue.props["activeTab"] == "comment"
      assert vue.props["unread"]["comment"] == 1
      assert vue.props["unread"]["series"] == 0
      assert [%{"action" => "comment_upvote"}] = vue.props["items"]
    end

    test "bell dropdown and page islands use distinct DOM ids", %{conn: conn} do
      user = AccountsFixtures.user_fixture()

      # The header bell (child LiveView) and the page each host a
      # NotificationPanel island. LiveVue auto-ids collide across LiveView
      # processes (per-process counter), which misroutes patches and
      # freezes island updates — so both ids are explicit and unique.
      {:ok, _view, html} = conn |> log_in(user) |> live(~p"/notifications")

      assert html =~ ~s(id="notification-panel-dropdown")
      assert html =~ ~s(id="notification-panel-page")
    end

    test "page wrapper breaks out of the layout gutters", %{conn: conn} do
      user = AccountsFixtures.user_fixture()

      {:ok, _view, html} = conn |> log_in(user) |> live(~p"/notifications")

      # Root layout main carries p-6; the page cancels the horizontal
      # gutters so the panel spans the viewport like the reference.
      assert html =~ ~s(class="-mx-6 px-3 sm:px-4")
      refute html =~ "max-w-140"
    end

    test "numbered pagination replaces the list per page", %{conn: conn} do
      user = AccountsFixtures.user_fixture()
      other = AccountsFixtures.user_fixture()
      series = CatalogFixtures.series_fixture()

      {:ok, parent} =
        Comments.create_comment(%{
          user_id: user.id,
          series_id: series.id,
          body_markdown: "parent comment"
        })

      for n <- 1..25 do
        {:ok, _} =
          Comments.create_comment(%{
            user_id: other.id,
            series_id: series.id,
            parent_id: parent.id,
            body_markdown: "reply #{n}"
          })
      end

      {:ok, view, _html} = conn |> log_in(user) |> live(~p"/notifications")

      vue = LiveVue.Test.get_vue(view)
      assert vue.props["page"] == 1
      assert vue.props["totalPages"] == 2
      assert length(vue.props["items"]) == 20

      render_hook(view, "notifications_page", %{"page" => "2"})

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.page == 2
      assert assigns.total_pages == 2
      assert assigns.paged == true
      assert length(assigns.items) == 5

      # Out-of-range input clamps to the nearest valid page.
      render_hook(view, "notifications_page", %{"page" => "999"})
      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.page == 2
      assert length(assigns.items) == 5

      render_hook(view, "notifications_page", %{"page" => "0"})
      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.page == 1
      assert assigns.paged == false
      assert length(assigns.items) == 20
    end

    test "switching tabs patches the URL and reloads the list", %{conn: conn} do
      user = AccountsFixtures.user_fixture()
      series = CatalogFixtures.series_fixture()
      chapter = CatalogFixtures.chapter_fixture(series)

      assert {:ok, _} = Library.bookmark_series(user, series)
      assert {:ok, 1} = Notifications.notify_series_chapter(series.id, chapter.id)

      {:ok, view, _html} = conn |> log_in(user) |> live(~p"/notifications")

      # SSR is disabled in test so the island renders a placeholder;
      # drive the LiveView event directly like a client pushEvent would.
      render_hook(view, "notifications_tab", %{"tab" => "series"})

      assert_patch(view, "/notifications?tab=series")

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.active_tab == "series"
      assert [%{action: "series_chapter"}] = assigns.items
    end

    test "marking one item read updates counts without reload", %{conn: conn} do
      user = AccountsFixtures.user_fixture()
      other = AccountsFixtures.user_fixture()
      series = CatalogFixtures.series_fixture()

      {:ok, comment} =
        Comments.create_comment(%{
          user_id: user.id,
          series_id: series.id,
          body_markdown: "my comment"
        })

      assert {:ok, _} = Comments.vote_comment(other, comment, 1)

      {:ok, view, _html} = conn |> log_in(user) |> live(~p"/notifications")

      [item] = LiveVue.Test.get_vue(view).props["items"]

      render_hook(view, "notifications_mark_read", %{"scope" => "item", "id" => item["id"]})

      # get_vue does not merge prop diffs, so read post-event state
      # from the socket; the DB assertion below proves persistence.
      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.unread_counts == %{comment: 0, series: 0, total: 0}
      assert [%{read_at: read_at}] = assigns.items
      assert is_binary(read_at)
      assert Notifications.unread_count(user.id) == 0
    end

    test "comment activity broadcasts on the recipient topic", %{conn: conn} do
      _ = conn
      user = AccountsFixtures.user_fixture()
      other = AccountsFixtures.user_fixture()
      series = CatalogFixtures.series_fixture()

      {:ok, comment} =
        Comments.create_comment(%{
          user_id: user.id,
          series_id: series.id,
          body_markdown: "my comment"
        })

      Phoenix.PubSub.subscribe(Crysa.PubSub, "notifications:#{user.id}")
      assert {:ok, _} = Comments.vote_comment(other, comment, 1)

      assert_receive {:notification_created, %{action: "comment_upvote"}}
    end

    test "realtime arrival refreshes counts and the visible page", %{conn: conn} do
      user = AccountsFixtures.user_fixture()
      other = AccountsFixtures.user_fixture()
      series = CatalogFixtures.series_fixture()

      {:ok, comment} =
        Comments.create_comment(%{
          user_id: user.id,
          series_id: series.id,
          body_markdown: "my comment"
        })

      {:ok, view, _html} = conn |> log_in(user) |> live(~p"/notifications")

      send(view.pid, {:notification_created, %{action: "comment_upvote"}})
      # Force the LiveView to process its mailbox before asserting.
      _ = render(view)

      # The row does not exist in the DB (synthetic event), so the list
      # stays empty but counts are recomputed from source of truth.
      assert {:ok, _} = Comments.vote_comment(other, comment, 1)
      send(view.pid, {:notification_created, %{action: "comment_upvote"}})
      _ = render(view)

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.unread_counts == %{comment: 1, series: 0, total: 1}
      assert [%{action: "comment_upvote"}] = assigns.items
    end

    test "header bell dropdown renders on dead pages with a live badge", %{conn: conn} do
      user = AccountsFixtures.user_fixture()
      other = AccountsFixtures.user_fixture()
      series = CatalogFixtures.series_fixture()

      {:ok, comment} =
        Comments.create_comment(%{
          user_id: user.id,
          series_id: series.id,
          body_markdown: "my comment"
        })

      assert {:ok, _} = Comments.vote_comment(other, comment, 1)

      # Dead controller page dead-renders the bell child LiveView.
      html = conn |> log_in(user) |> get(~p"/series") |> html_response(200)

      assert html =~ "aria-label=\"Notifications\""
      # Dead render carries the unread snapshot badge.
      assert html =~ "bg-[#DC2626] px-1"
      # Hamburger badge always renders with a stable id so the bell's
      # live hook can mirror counts into it (hidden when zero).
      assert html =~ "hamburger-notif-count"

      # Guests get no bell at all.
      guest_html = get(conn, ~p"/series") |> html_response(200)
      refute guest_html =~ "aria-label=\"Notifications\""
    end
  end

  describe "notification bell dropdown" do
    test "mount preloads the 5-newest-unread preview", %{conn: conn} do
      user = AccountsFixtures.user_fixture()
      other = AccountsFixtures.user_fixture()
      series = CatalogFixtures.series_fixture()

      {:ok, parent} =
        Comments.create_comment(%{
          user_id: user.id,
          series_id: series.id,
          body_markdown: "my comment"
        })

      # More unread rows than the preview window, plus one read row that
      # must never appear in the dropdown.
      for n <- 1..6 do
        {:ok, reply} =
          Comments.create_comment(%{
            user_id: other.id,
            series_id: series.id,
            parent_id: parent.id,
            body_markdown: "reply #{n}"
          })

        if n == 1 do
          {:ok, {rows, _}} = Notifications.list_notifications(user.id, "comment", limit: 50)
          row = Enum.find(rows, &(&1.comment.id == reply.id))
          {:ok, _} = Notifications.mark_as_read(user.id, %{scope: "item", id: row.id})
        end
      end

      assert {:ok, _} = Comments.vote_comment(other, parent, 1)

      {:ok, bell, _html} = live_bell(conn, user)
      assigns = :sys.get_state(bell.pid).socket.assigns

      # Capped at 5, unread only, newest first — so the dropdown can
      # never stretch the viewport and never needs its own pager.
      assert [%{}, %{}, %{}, %{}, %{}] = assigns.items
      assert Enum.all?(assigns.items, &is_nil(&1.read_at))
      assert assigns.has_more == true
      assert assigns.unread_counts == %{comment: 6, series: 0, total: 6}

      vue = LiveVue.Test.get_vue(render(bell))
      assert vue.props["showLoadMore"] == false
    end

    test "open report refetches so reopen never shows stale rows", %{conn: conn} do
      user = AccountsFixtures.user_fixture()
      other = AccountsFixtures.user_fixture()
      series = CatalogFixtures.series_fixture()

      {:ok, bell, _html} = live_bell(conn, user)

      {:ok, comment} =
        Comments.create_comment(%{
          user_id: user.id,
          series_id: series.id,
          body_markdown: "my comment"
        })

      assert {:ok, _} = Comments.vote_comment(other, comment, 1)

      # Read happened outside the dropdown (page center, other device):
      # reopen must pick it up instead of serving the mount snapshot.
      {:ok, {rows, _}} = Notifications.list_notifications(user.id, "comment", limit: 50)
      row = hd(rows)
      {:ok, _} = Notifications.mark_as_read(user.id, %{scope: "item", id: row.id})

      render_hook(bell, "notifications_opened", %{})

      assigns = :sys.get_state(bell.pid).socket.assigns
      assert assigns.loaded == true
      assert assigns.items == []
      assert assigns.unread_counts == %{comment: 0, series: 0, total: 0}
    end

    test "marking one dropdown item refills the preview window", %{conn: conn} do
      user = AccountsFixtures.user_fixture()
      other = AccountsFixtures.user_fixture()
      series = CatalogFixtures.series_fixture()

      {:ok, parent} =
        Comments.create_comment(%{
          user_id: user.id,
          series_id: series.id,
          body_markdown: "my comment"
        })

      for n <- 1..6 do
        {:ok, _} =
          Comments.create_comment(%{
            user_id: other.id,
            series_id: series.id,
            parent_id: parent.id,
            body_markdown: "reply #{n}"
          })
      end

      {:ok, bell, _html} = live_bell(conn, user)
      before = :sys.get_state(bell.pid).socket.assigns
      assert length(before.items) == 5
      assert before.has_more == true

      [first | _] = before.items
      render_hook(bell, "notifications_mark_read", %{"scope" => "item", "id" => first.id})

      # Unread-only preview must backfill the 6th row instead of
      # leaving a 4-row hole with a stale cursor.
      assigns = :sys.get_state(bell.pid).socket.assigns
      assert length(assigns.items) == 5
      assert assigns.has_more == false
      assert assigns.unread_counts == %{comment: 5, series: 0, total: 5}

      {:ok, {expected, _}} =
        Notifications.list_notifications(user.id, "comment", limit: 5, unread_only: true)

      assert Enum.map(assigns.items, & &1.id) == Enum.map(expected, & &1.id)
    end

    test "tab switch, mark read, and realtime arrival inside the dropdown", %{conn: conn} do
      user = AccountsFixtures.user_fixture()
      other = AccountsFixtures.user_fixture()
      series = CatalogFixtures.series_fixture()
      chapter = CatalogFixtures.chapter_fixture(series)

      assert {:ok, _} = Library.bookmark_series(user, series)
      assert {:ok, 1} = Notifications.notify_series_chapter(series.id, chapter.id)

      {:ok, bell, _html} = live_bell(conn, user)
      render_hook(bell, "notifications_opened", %{})

      render_hook(bell, "notifications_tab", %{"tab" => "series"})
      assigns = :sys.get_state(bell.pid).socket.assigns
      assert assigns.active_tab == "series"
      assert [%{action: "series_chapter"}] = assigns.items

      [item] = assigns.items
      render_hook(bell, "notifications_mark_read", %{"scope" => "item", "id" => item.id})

      # Read rows clear out of the dropdown instead of greying out.
      assigns = :sys.get_state(bell.pid).socket.assigns
      assert assigns.unread_counts.series == 0
      assert assigns.items == []

      # Realtime arrival while open refreshes the visible page.
      {:ok, comment} =
        Comments.create_comment(%{
          user_id: user.id,
          series_id: series.id,
          body_markdown: "my comment"
        })

      assert {:ok, _} = Comments.vote_comment(other, comment, 1)
      render_hook(bell, "notifications_tab", %{"tab" => "comment"})

      assigns = :sys.get_state(bell.pid).socket.assigns
      assert assigns.unread_counts.comment == 1
      assert [%{action: "comment_upvote"}] = assigns.items
    end

    test "bell wiring is instant client-side with server-owned data",
         %{conn: conn} do
      user = AccountsFixtures.user_fixture()

      {:ok, bell, _html} = live_bell(conn, user)
      html = render(bell)

      {:ok, doc} = Floki.parse_document(html)

      # The toggle button sits INSIDE the click-away boundary; one bell
      # click toggles visibility and reports opened, never open+close.
      assert [_] = Floki.find(doc, "div[phx-click-away] button[aria-label='Notifications']")

      # Visibility needs no roundtrip: the button toggles the dropdown
      # instantly and reports the open for a staleness refresh.
      assert html =~ "notif-dropdown"
      assert html =~ "notifications_opened"

      # The island renders with the mount preload, so opens can never
      # enter a loading state.
      assert html =~ "NotificationPanel"

      # Mobile: fixed to the viewport with side margins so the panel can
      # never clip; desktop: anchored dropdown next to the bell.
      # Width follows the template (`sm:w-95` = 380px in Tailwind v4
      # dynamic spacing); the test tracks the template, not vice versa.
      assert html =~ "fixed inset-x-2"
      assert html =~ "sm:absolute"
      assert html =~ "sm:w-95"
    end

    test "bell refreshes a preloaded feed on realtime arrival", %{conn: conn} do
      user = AccountsFixtures.user_fixture()
      other = AccountsFixtures.user_fixture()
      series = CatalogFixtures.series_fixture()

      {:ok, comment} =
        Comments.create_comment(%{
          user_id: user.id,
          series_id: series.id,
          body_markdown: "my comment"
        })

      {:ok, bell, _html} = live_bell(conn, user)

      # Feed preloads on mount, so arrivals refresh it directly.
      assert :sys.get_state(bell.pid).socket.assigns.items == []

      assert {:ok, _} = Comments.vote_comment(other, comment, 1)
      send(bell.pid, {:notification_created, %{action: "comment_upvote"}})
      _ = render(bell)

      assigns = :sys.get_state(bell.pid).socket.assigns
      assert assigns.unread_counts == %{comment: 1, series: 0, total: 1}
      assert [%{action: "comment_upvote"}] = assigns.items
    end
  end

  defp live_bell(conn, user) do
    token = Accounts.generate_user_session_token(user)
    live_isolated(conn, CrysaWeb.Live.NotificationBellLive, session: %{"user_token" => token})
  end

  defp log_in(conn, user) do
    token = Accounts.generate_user_session_token(user)
    conn |> Plug.Test.init_test_session(%{}) |> put_session(:user_token, token)
  end
end
