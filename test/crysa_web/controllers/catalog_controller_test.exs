defmodule CrysaWeb.CatalogControllerTest do
  use CrysaWeb.ConnCase, async: true

  alias Crysa.Catalog
  alias Crysa.CatalogFixtures

  describe "GET /" do
    test "renders new series on the home page", %{conn: conn} do
      series = CatalogFixtures.series_fixture()

      conn = get(conn, ~p"/")

      assert html_response(conn, 200) =~ "New Series"
      assert html_response(conn, 200) =~ series.title
    end
  end

  describe "GET /series" do
    test "renders the browse page with series", %{conn: conn} do
      series = CatalogFixtures.series_fixture()

      conn = get(conn, ~p"/series")

      assert html_response(conn, 200) =~ "Browse Series"
      assert html_response(conn, 200) =~ series.title
    end

    test "filters by search term", %{conn: conn} do
      wanted = CatalogFixtures.series_fixture(%{title: "Unique Manga Story"})
      CatalogFixtures.series_fixture(%{title: "Other Title"})

      conn = get(conn, ~p"/series", q: "unique")

      assert html_response(conn, 200) =~ wanted.title
      refute html_response(conn, 200) =~ "Other Title"
    end

    test "filters by category", %{conn: conn} do
      category = CatalogFixtures.category_fixture("Action")
      tagged = CatalogFixtures.series_fixture()
      {:ok, _} = Catalog.set_series_categories(tagged, [category])
      untagged = CatalogFixtures.series_fixture()

      conn = get(conn, ~p"/series", category: "Action")

      assert html_response(conn, 200) =~ tagged.title
      refute html_response(conn, 200) =~ untagged.title
    end

    test "renders an empty state when nothing matches", %{conn: conn} do
      conn = get(conn, ~p"/series", q: "no such title")

      assert html_response(conn, 200) =~ "No series match your filters"
    end

    test "clamps out-of-range pagination params without errors", %{conn: conn} do
      CatalogFixtures.series_fixture()

      conn = get(conn, ~p"/series", page: "99999", page_size: "9999")

      assert html_response(conn, 200) =~ "Browse Series"
    end
  end

  describe "GET /popular" do
    test "renders most viewed series", %{conn: conn} do
      series = CatalogFixtures.series_fixture(%{view_count: 50})

      conn = get(conn, ~p"/popular")

      assert html_response(conn, 200) =~ "Most Viewed"
      assert html_response(conn, 200) =~ series.title
    end
  end

  describe "GET /updates" do
    test "renders latest updated series", %{conn: conn} do
      series = CatalogFixtures.series_fixture()

      conn = get(conn, ~p"/updates")

      assert html_response(conn, 200) =~ "Latest Updates"
      assert html_response(conn, 200) =~ series.title
    end
  end

  describe "GET /tags" do
    test "renders tags with series counts", %{conn: conn} do
      category = CatalogFixtures.category_fixture("Fantasy")
      series = CatalogFixtures.series_fixture()
      {:ok, _} = Catalog.set_series_categories(series, [category])

      conn = get(conn, ~p"/tags")

      assert html_response(conn, 200) =~ "Tags"
      assert html_response(conn, 200) =~ "Fantasy"
    end

    test "omits categories without series", %{conn: conn} do
      CatalogFixtures.category_fixture("Empty Tag")

      conn = get(conn, ~p"/tags")

      refute html_response(conn, 200) =~ "Empty Tag"
    end
  end

  describe "GET /series/:slug (LiveView — SeriesPage mobile)" do
    test "renders the series detail LiveView with chapters (SSR + LiveVue)", %{conn: conn} do
      series = CatalogFixtures.series_fixture()
      chapter = CatalogFixtures.chapter_fixture(series)

      # Series detail is now a LiveView (SeriesShowLive) with LiveVue island `SeriesPage` (v-ssr=true).
      # Dead render is not assertable via `get` HTML because LiveView uses `data-phx-static` compression;
      # use `live` helper which decodes the static and renders SSR HTML.
      import Phoenix.LiveViewTest

      {:ok, view, _html} = live(conn, ~p"/series/#{series.slug}")

      # The page is a LiveVue island; verify via the Vue props and via rendered HTML
      vue = LiveVue.Test.get_vue(view)
      assert vue.component == "SeriesPage"
      assert vue.props["series"]["title"] == series.title
      assert vue.props["series"]["slug"] == series.slug

      # Chapters are passed as props and SSR-rendered
      assert Enum.any?(vue.props["chapters"], fn ch ->
               ch["displayNumber"] == chapter.display_number
             end)

      # In test, SSR is disabled (data-ssr="false"), so HTML is the LiveVue placeholder.
      # Verify via props and via the static HEEX wrapper not the Vue SSR output.
      assert vue.props["chapters"] != []

      # When SSR is enabled in dev/prod, "Chapters" will be server-rendered; in test we check props instead.
    end

    test "shows not-found for an unknown slug (LiveView renders 200 with message)", %{conn: conn} do
      import Phoenix.LiveViewTest

      {:ok, view, _html} = live(conn, ~p"/series/does-not-exist")

      html = render(view)
      assert html =~ "Series not found"
    end
  end

  describe "GET /series/:slug/:chapter_key" do
    test "renders the reader with images and navigation", %{conn: conn} do
      series = CatalogFixtures.series_fixture()
      chapter = CatalogFixtures.chapter_fixture(series, %{chapter_key: "1", sort_key: "000001"})
      CatalogFixtures.chapter_fixture(series, %{chapter_key: "2", sort_key: "000002"})
      image = CatalogFixtures.chapter_image_fixture(chapter)

      conn = get(conn, ~p"/series/#{series.slug}/1")

      html = html_response(conn, 200)
      assert html =~ series.title
      assert html =~ "Chapter #{chapter.display_number}"
      assert html =~ image.source_url
      assert html =~ "Next"
    end

    test "returns 404 for an unknown chapter", %{conn: conn} do
      series = CatalogFixtures.series_fixture()

      conn = get(conn, ~p"/series/#{series.slug}/missing")

      assert html_response(conn, 404) =~ "Not Found"
    end
  end
end
