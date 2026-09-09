defmodule CrysaWeb.CatalogViewTrackingTest do
  @moduledoc """
  View tracking semantics: chapter reads count, series page impressions do not.

  The open series page receives coalesced `{:view_count_updated, _, _}`
  broadcasts so stats update without refresh.
  """

  use CrysaWeb.ConnCase, async: false

  alias Crysa.Accounts
  alias Crysa.AccountsFixtures
  alias Crysa.CatalogFixtures
  alias Crysa.Library
  alias Crysa.Repo

  test "GET reader counts a view on the parent series", %{conn: conn} do
    series = CatalogFixtures.series_fixture()
    chapter = CatalogFixtures.chapter_fixture(series, %{chapter_key: "1", sort_key: "000001"})

    assert Repo.get!(Crysa.Catalog.Series, series.id).view_count == 0

    conn = get(conn, ~p"/series/#{series.slug}/#{chapter.chapter_key}")
    assert html_response(conn, 200) =~ series.title
    assert Repo.get!(Crysa.Catalog.Series, series.id).view_count == 1

    conn = Phoenix.ConnTest.build_conn() |> get(~p"/series/#{series.slug}/#{chapter.chapter_key}")
    assert html_response(conn, 200) =~ series.title
    assert Repo.get!(Crysa.Catalog.Series, series.id).view_count == 2
  end

  test "series LiveView mount does not count a view", %{conn: conn} do
    import Phoenix.LiveViewTest

    series = CatalogFixtures.series_fixture()
    CatalogFixtures.chapter_fixture(series)

    {:ok, _view, _html} = live(conn, ~p"/series/#{series.slug}")

    assert Repo.get!(Crysa.Catalog.Series, series.id).view_count == 0
  end

  test "GET reader records reading progress for logged-in users", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    series = CatalogFixtures.series_fixture()
    chapter = CatalogFixtures.chapter_fixture(series, %{chapter_key: "10", sort_key: "000010"})

    conn = conn |> log_in(user) |> get(~p"/series/#{series.slug}/#{chapter.chapter_key}")
    assert html_response(conn, 200) =~ series.title

    progress = Library.get_reading_progress(user, series)
    assert progress.last_chapter_id == chapter.id
  end

  test "GET reader records nothing for guests", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    series = CatalogFixtures.series_fixture()
    chapter = CatalogFixtures.chapter_fixture(series, %{chapter_key: "10", sort_key: "000010"})

    conn = get(conn, ~p"/series/#{series.slug}/#{chapter.chapter_key}")
    assert html_response(conn, 200) =~ series.title

    assert Library.get_reading_progress(user, series) == nil
    assert Repo.aggregate(Crysa.Library.ReadingProgress, :count, :id) == 0
  end

  defp log_in(conn, user) do
    token = Accounts.generate_user_session_token(user)
    conn |> Plug.Test.init_test_session(%{}) |> put_session(:user_token, token)
  end

  defp eventually(fun, attempts \\ 20)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(25)
      eventually(fun, attempts - 1)
    end
  end

  test "open series page receives view count broadcast without refresh", %{conn: conn} do
    import Phoenix.LiveViewTest

    series = CatalogFixtures.series_fixture()
    CatalogFixtures.chapter_fixture(series)

    {:ok, view, _html} = live(conn, ~p"/series/#{series.slug}")

    vue = LiveVue.Test.get_vue(view)
    assert get_in(vue.props, ["stats", "views"]) == 0

    # Simulate the coalesced broadcast from a chapter read elsewhere.
    # LiveVue sends prop diffs, so assert on props_diff without a page refresh.
    send(view.pid, {:view_count_updated, 7, series.id})

    assert eventually(fn ->
             vue = LiveVue.Test.get_vue(view)
             Enum.any?(vue.props_diff, &(&1 == ["replace", "/stats/views", 7]))
           end)
  end
end
