defmodule CrysaWeb.CatalogControllerTest do
  use CrysaWeb.ConnCase, async: true

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
    # Browse is now a LiveView (`BrowseLive` rendering the full-Vue
    # `BrowsePage`); coverage lives in `CrysaWeb.BrowseLiveTest`.
    test "routes to the browse LiveView", %{conn: conn} do
      CatalogFixtures.series_fixture()

      import Phoenix.LiveViewTest
      {:ok, view, _html} = live(conn, ~p"/series")

      vue = LiveVue.Test.get_vue(view)
      assert vue.component == "BrowsePage"
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

  describe "GET /series tri-state genre filter" do
    # Covered in `CrysaWeb.BrowseLiveTest` (toggle cycle + include/exclude).
    test "toggle cycle lives in the browse LiveView", %{conn: conn} do
      import Phoenix.LiveViewTest
      {:ok, view, _html} = live(conn, ~p"/series")

      render_hook(view, "browse_toggle_tag", %{"name" => "Fantasy"})
      assert_patch(view, "/series?category=Fantasy")
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
