defmodule CrysaWeb.BrowseLiveTest do
  @moduledoc """
  Covers the `/series` browse page: public access, island props, tri-state
  genre filter, search/sort/status, paging, and card enrichment.

  Note on assertions: LiveVue streams post-mount updates as `props_diff`
  (JSON patch), so after `render_hook` we read server assigns directly —
  the same pattern as `BookmarkLiveTest` — instead of re-decoding
  `data-props`.
  """

  use CrysaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Crysa.Catalog
  alias Crysa.CatalogFixtures

  test "guests can browse without signing in", %{conn: conn} do
    CatalogFixtures.series_fixture()

    {:ok, view, _html} = live(conn, ~p"/series")

    vue = LiveVue.Test.get_vue(view)
    assert vue.component == "BrowsePage"
  end

  test "renders entries, pagination, categories, and sketch defaults", %{conn: conn} do
    series = CatalogFixtures.series_fixture()
    category = CatalogFixtures.category_fixture("Fantasy")
    {:ok, _} = Catalog.set_series_categories(series, [category])

    {:ok, view, _html} = live(conn, ~p"/series")

    vue = LiveVue.Test.get_vue(view)
    assert vue.props["sort"] == "latest_updates"
    assert vue.props["query"] == ""
    assert vue.props["pubStatus"] == ""
    assert vue.props["includeTags"] == []
    assert vue.props["excludeTags"] == []
    assert vue.props["pagination"]["totalEntries"] == 1

    assert [%{"slug" => slug, "title" => title}] = vue.props["entries"]
    assert slug == series.slug
    assert title == series.title

    assert Enum.any?(vue.props["categories"], &(&1["name"] == "Fantasy"))
  end

  test "search narrows the list and patches the URL", %{conn: conn} do
    CatalogFixtures.series_fixture(%{title: "Unique Manga Story"})
    CatalogFixtures.series_fixture(%{title: "Other Title"})

    {:ok, view, _html} = live(conn, ~p"/series")

    render_hook(view, "browse_search", %{"q" => "unique"})
    assert_patch(view, "/series?q=unique")

    assigns = :sys.get_state(view.pid).socket.assigns
    assert [%{title: "Unique Manga Story"}] = assigns.entries

    # The island must receive entry updates over the live channel; if the
    # diff carried no /entries ops, the grid could only refresh via reload.
    diff = LiveVue.Test.get_vue(view).props_diff

    assert Enum.any?(diff, fn
             [_, "/entries" <> _, _] -> true
             [_, "/entries" <> _] -> true
             _ -> false
           end)
  end

  test "sort and status patch the URL and narrow the list", %{conn: conn} do
    CatalogFixtures.series_fixture(%{publication_status: "ongoing"})
    completed = CatalogFixtures.series_fixture(%{publication_status: "completed"})

    {:ok, view, _html} = live(conn, ~p"/series")

    render_hook(view, "browse_sort", %{"sort" => "most_viewed"})
    assert_patch(view, "/series?sort=most_viewed")

    render_hook(view, "browse_status", %{"status" => "completed"})
    assert_patch(view, "/series?sort=most_viewed&publication_status=completed")

    assigns = :sys.get_state(view.pid).socket.assigns
    assert assigns.sort == "most_viewed"
    assert assigns.pub_status == "completed"
    assert [%{id: id}] = assigns.entries
    assert id == completed.id
  end

  test "genre toggle cycles none -> include -> exclude -> none", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/series")

    render_hook(view, "browse_toggle_tag", %{"name" => "Action"})
    assert_patch(view, "/series?category=Action")

    assigns = :sys.get_state(view.pid).socket.assigns
    assert assigns.include_tags == ["Action"]
    assert assigns.exclude_tags == []

    render_hook(view, "browse_toggle_tag", %{"name" => "Action"})
    assert_patch(view, "/series?exclude_category=Action")

    assigns = :sys.get_state(view.pid).socket.assigns
    assert assigns.include_tags == []
    assert assigns.exclude_tags == ["Action"]

    render_hook(view, "browse_toggle_tag", %{"name" => "Action"})
    assert_patch(view, "/series")

    assigns = :sys.get_state(view.pid).socket.assigns
    assert assigns.include_tags == []
    assert assigns.exclude_tags == []
  end

  test "include/exclude filters narrow the list", %{conn: conn} do
    [action, drama] = CatalogFixtures.categories_fixture(["Action", "Drama"])
    included = CatalogFixtures.series_fixture(%{title: "Included Only Story"})
    {:ok, _} = Catalog.set_series_categories(included, [action])
    excluded = CatalogFixtures.series_fixture(%{title: "Excluded Only Story"})
    {:ok, _} = Catalog.set_series_categories(excluded, [drama])

    {:ok, view, _html} = live(conn, ~p"/series?category=Action")

    vue = LiveVue.Test.get_vue(view)
    titles = Enum.map(vue.props["entries"], & &1["title"])
    assert "Included Only Story" in titles
    refute "Excluded Only Story" in titles

    {:ok, view, _html} = live(conn, ~p"/series?exclude_category=Drama")

    vue = LiveVue.Test.get_vue(view)
    titles = Enum.map(vue.props["entries"], & &1["title"])
    assert "Included Only Story" in titles
    refute "Excluded Only Story" in titles
  end

  test "reset clears genre filters but keeps the search", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/series?q=unique&category=Action")

    render_hook(view, "browse_reset", %{})
    assert_patch(view, "/series?q=unique")

    assigns = :sys.get_state(view.pid).socket.assigns
    assert assigns.include_tags == []
    assert assigns.exclude_tags == []
    assert assigns.query == "unique"
  end

  test "paging patches the URL and clamps out-of-range pages", %{conn: conn} do
    for _ <- 1..3, do: CatalogFixtures.series_fixture()

    {:ok, view, _html} = live(conn, ~p"/series")

    render_hook(view, "browse_page", %{"page" => "999"})
    assert_patch(view, "/series?page=999")

    # The query layer clamps to the last page, so the island still renders.
    assigns = :sys.get_state(view.pid).socket.assigns
    assert assigns.page == 1
    assert match?([_, _, _], assigns.entries)
  end

  test "empty result set renders an empty entries list", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/series?q=no+such+title")

    vue = LiveVue.Test.get_vue(view)
    assert vue.props["entries"] == []
    assert vue.props["pagination"]["totalEntries"] == 0
  end

  test "cards carry first chapter, rating, and trending flags", %{conn: conn} do
    series =
      CatalogFixtures.series_fixture(%{view_count: 28_551, rating_count: 2, rating_sum: 9.0})

    CatalogFixtures.chapter_fixture(series, %{
      display_number: "1",
      chapter_key: "ch-1",
      sort_key: "000001"
    })

    CatalogFixtures.chapter_fixture(series, %{
      display_number: "48",
      chapter_key: "ch-48",
      sort_key: "000048"
    })

    {:ok, view, _html} = live(conn, ~p"/series")

    vue = LiveVue.Test.get_vue(view)

    assert [
             %{
               "viewCount" => 28_551,
               "ratingAverage" => 4.5,
               "trending" => true,
               "firstChapter" => %{"displayNumber" => "1", "chapterKey" => "ch-1"}
             }
           ] = vue.props["entries"]
  end

  test "cards omit user-specific progress fields", %{conn: conn} do
    series = CatalogFixtures.series_fixture()

    CatalogFixtures.chapter_fixture(series, %{
      display_number: "1",
      chapter_key: "ch-1",
      sort_key: "000001"
    })

    {:ok, view, _html} = live(conn, ~p"/series")

    vue = LiveVue.Test.get_vue(view)
    assert [%{"firstChapter" => %{"chapterKey" => "ch-1"}}] = vue.props["entries"]
    refute Map.has_key?(hd(vue.props["entries"]), "hasUnread")
    refute Map.has_key?(hd(vue.props["entries"]), "lastReading")
    refute Map.has_key?(hd(vue.props["entries"]), "latestChapter")
  end

  test "catalog broadcasts bump the refresh pill counter", %{conn: conn} do
    CatalogFixtures.series_fixture()

    {:ok, view, _html} = live(conn, ~p"/series")
    assert :sys.get_state(view.pid).socket.assigns.pending_updates == 0

    Phoenix.PubSub.broadcast(Crysa.PubSub, "catalog:updates", :catalog_updated)
    _ = render(view)
    assert :sys.get_state(view.pid).socket.assigns.pending_updates == 1

    Phoenix.PubSub.broadcast(Crysa.PubSub, "catalog:updates", :catalog_updated)
    _ = render(view)
    assert :sys.get_state(view.pid).socket.assigns.pending_updates == 2
  end

  test "refresh reloads at page 1 with filters kept and resets the pill", %{conn: conn} do
    CatalogFixtures.series_fixture()

    {:ok, view, _html} = live(conn, ~p"/series?q=quest&category=Action")

    Phoenix.PubSub.broadcast(Crysa.PubSub, "catalog:updates", :catalog_updated)
    _ = render(view)

    render_hook(view, "browse_refresh", %{})
    assert_patch(view, "/series?q=quest&category=Action")

    assigns = :sys.get_state(view.pid).socket.assigns
    assert assigns.pending_updates == 0
    assert assigns.page == 1
  end

  test "view count broadcasts patch the card in place", %{conn: conn} do
    series = CatalogFixtures.series_fixture(%{view_count: 10})

    {:ok, view, _html} = live(conn, ~p"/series")

    send(view.pid, {:view_count_updated, 28_551, series.id})
    _ = render(view)

    assert [%{viewCount: 28_551, trending: true}] =
             :sys.get_state(view.pid).socket.assigns.entries
  end

  test "rating broadcasts patch the card average in place", %{conn: conn} do
    series = CatalogFixtures.series_fixture()

    {:ok, view, _html} = live(conn, ~p"/series")

    send(view.pid, {:rating_updated, %{count: 4, sum: 18.0, average: 4.5}, [], series.id})
    _ = render(view)

    assert [%{ratingAverage: 4.5, ratingCount: 4}] =
             :sys.get_state(view.pid).socket.assigns.entries
  end

  test "broadcasts for off-page series are ignored", %{conn: conn} do
    CatalogFixtures.series_fixture()

    {:ok, view, _html} = live(conn, ~p"/series")

    before = :sys.get_state(view.pid).socket.assigns.entries
    send(view.pid, {:view_count_updated, 99_999, -1})
    _ = render(view)

    assert :sys.get_state(view.pid).socket.assigns.entries == before
  end
end
