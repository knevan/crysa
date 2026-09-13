defmodule CrysaWeb.BookmarkLiveTest do
  @moduledoc """
  Covers the `/bookmarks` library page: auth, island props, filtering, paging.
  """

  use CrysaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Crysa.Accounts
  alias Crysa.AccountsFixtures
  alias Crysa.CatalogFixtures
  alias Crysa.Library

  test "redirects guests to login", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/auth/login"}}} = live(conn, ~p"/bookmarks")
  end

  test "header user menus use an opaque background", %{conn: conn} do
    user = AccountsFixtures.user_fixture()

    {:ok, _view, html} = conn |> log_in(user) |> live(~p"/bookmarks")

    # Regression: with daisyUI themes disabled, `bg-base-100` resolves to an
    # undefined variable (transparent), letting page text pass through the
    # open menu. Both menus must use an opaque token background that also
    # follows dark mode (`bg-popover` is opaque in both themes).
    assert html =~ "dropdown-content menu bg-popover"
    assert html =~ "menu menu-sm dropdown-content bg-popover"
    assert html =~ ~s(href="/bookmarks")
  end

  test "renders the BookmarkLibrary island with entries and pagination", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    series = CatalogFixtures.series_fixture()

    CatalogFixtures.chapter_fixture(series, %{display_number: "48", chapter_key: "ch-48"})

    assert {:ok, _} = Library.bookmark_series(user, series)

    {:ok, view, _html} = conn |> log_in(user) |> live(~p"/bookmarks")

    vue = LiveVue.Test.get_vue(view)
    assert vue.component == "BookmarkLibrary"
    assert vue.props["status"] == "all"
    assert vue.props["sortBy"] == "latest_update"
    assert vue.props["order"] == "desc"

    # The Latest deep link needs both keys; dropping chapterKey would
    # silently revert the card to a series-page link.
    assert [
             %{
               "slug" => slug,
               "title" => title,
               "latestChapter" => %{"displayNumber" => "48", "chapterKey" => "ch-48"}
             }
           ] = vue.props["entries"]

    assert title == series.title
    assert slug == series.slug
    assert vue.props["pagination"]["totalEntries"] == 1
  end

  test "status filter patches the URL and narrows the list", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    ongoing = CatalogFixtures.series_fixture(%{publication_status: "ongoing"})
    completed = CatalogFixtures.series_fixture(%{publication_status: "completed"})
    assert {:ok, _} = Library.bookmark_series(user, ongoing)
    assert {:ok, _} = Library.bookmark_series(user, completed)

    {:ok, view, _html} = conn |> log_in(user) |> live(~p"/bookmarks")

    render_hook(view, "bookmarks_filter", %{
      "status" => "completed",
      "sort_by" => "latest_update",
      "order" => "desc"
    })

    assert_patch(view, "/bookmarks?status=completed&sort_by=latest_update&order=desc")

    assigns = :sys.get_state(view.pid).socket.assigns
    assert assigns.status == "completed"
    assert [%{id: id}] = assigns.entries
    assert id == completed.id
  end

  test "filter change streams entry updates to the island (no refresh needed)", %{
    conn: conn
  } do
    user = AccountsFixtures.user_fixture()
    ongoing = CatalogFixtures.series_fixture(%{publication_status: "ongoing"})
    completed = CatalogFixtures.series_fixture(%{publication_status: "completed"})
    assert {:ok, _} = Library.bookmark_series(user, ongoing)
    assert {:ok, _} = Library.bookmark_series(user, completed)

    {:ok, view, _html} = conn |> log_in(user) |> live(~p"/bookmarks")

    render_hook(view, "bookmarks_filter", %{
      "status" => "completed",
      "sort_by" => "latest_update",
      "order" => "desc"
    })

    # The island must receive entry updates over the live channel; if the
    # diff carried no /entries ops, the grid could only refresh via reload.
    diff = LiveVue.Test.get_vue(view).props_diff

    assert Enum.any?(diff, fn
             [_, "/entries" <> _, _] -> true
             [_, "/entries" <> _] -> true
             _ -> false
           end)
  end

  test "entries expose last reading with a reader chapter key", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    series = CatalogFixtures.series_fixture()

    read =
      CatalogFixtures.chapter_fixture(series, %{
        display_number: "10",
        chapter_key: "ch-10",
        sort_key: "000010"
      })

    CatalogFixtures.chapter_fixture(series, %{
      display_number: "18",
      chapter_key: "ch-18",
      sort_key: "000018"
    })

    assert {:ok, _} = Library.bookmark_series(user, series)
    assert {:ok, _} = Library.record_reading_progress(user, series, read)

    {:ok, view, _html} = conn |> log_in(user) |> live(~p"/bookmarks")

    assert [
             %{
               "lastReading" => %{"displayNumber" => "10", "chapterKey" => "ch-10"},
               "latestChapter" => %{"displayNumber" => "18"},
               "hasUnread" => true
             }
           ] = LiveVue.Test.get_vue(view).props["entries"]
  end

  test "badge clears once the user reads the latest chapter", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    series = CatalogFixtures.series_fixture()

    latest =
      CatalogFixtures.chapter_fixture(series, %{
        display_number: "18",
        chapter_key: "ch-18",
        sort_key: "000018"
      })

    assert {:ok, _} = Library.bookmark_series(user, series)
    assert {:ok, _} = Library.record_reading_progress(user, series, latest)

    {:ok, view, _html} = conn |> log_in(user) |> live(~p"/bookmarks")

    assert [%{"hasUnread" => false, "lastReading" => %{"displayNumber" => "18"}}] =
             LiveVue.Test.get_vue(view).props["entries"]
  end

  test "unbookmark removes the entry and decrements the counter", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    series = CatalogFixtures.series_fixture()
    assert {:ok, _} = Library.bookmark_series(user, series)

    {:ok, view, _html} = conn |> log_in(user) |> live(~p"/bookmarks")

    render_hook(view, "unbookmark", %{"id" => to_string(series.id)})

    assigns = :sys.get_state(view.pid).socket.assigns
    assert assigns.entries == []
    refute Library.bookmarked?(user, series)
  end

  test "invalid unbookmark id does not crash", %{conn: conn} do
    user = AccountsFixtures.user_fixture()

    {:ok, view, _html} = conn |> log_in(user) |> live(~p"/bookmarks")
    html = render_hook(view, "unbookmark", %{"id" => "99999999"})

    assert is_binary(html)
    assigns = :sys.get_state(view.pid).socket.assigns
    assert assigns.entries == []
  end

  defp log_in(conn, user) do
    token = Accounts.generate_user_session_token(user)
    conn |> Plug.Test.init_test_session(%{}) |> put_session(:user_token, token)
  end
end
