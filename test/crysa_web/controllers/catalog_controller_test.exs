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

  describe "GET /series/:slug" do
    test "renders the series detail page with chapters", %{conn: conn} do
      series = CatalogFixtures.series_fixture()
      chapter = CatalogFixtures.chapter_fixture(series)

      conn = get(conn, ~p"/series/#{series.slug}")

      html = html_response(conn, 200)
      assert html =~ series.title
      assert html =~ "Chapter #{chapter.display_number}"
      assert html =~ "Read latest chapter"
    end

    test "returns 404 for an unknown slug", %{conn: conn} do
      conn = get(conn, ~p"/series/does-not-exist")

      assert html_response(conn, 404) =~ "Not Found"
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
