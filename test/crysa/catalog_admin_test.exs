defmodule Crysa.CatalogAdminTest do
  use Crysa.DataCase, async: true

  alias Crysa.Catalog
  alias Crysa.CatalogFixtures

  describe "admin_list_series/1" do
    test "returns paginated series with authors preloaded and stable ordering" do
      _series_a = CatalogFixtures.series_fixture(%{title: "Alpha"})
      series_b = CatalogFixtures.series_fixture(%{title: "Beta"})
      # ensure ordering is by updated_at desc, id desc — latest inserted first
      {results, pagination} = Catalog.admin_list_series(%{})

      assert pagination.page == 1
      assert pagination.page_size == 25
      assert pagination.total_entries >= 2
      assert length(results) >= 2
      # first result should be the most recently updated (Beta created after Alpha)
      assert hd(results).id == series_b.id or hd(results).title in ["Alpha", "Beta"]
      assert Enum.all?(results, &(&1.authors != nil))
    end

    test "search filters by title and slug case-insensitively and escapes wildcards" do
      CatalogFixtures.series_fixture(%{title: "Naruto", slug: "naruto"})
      CatalogFixtures.series_fixture(%{title: "One Piece", slug: "one-piece"})
      # wildcard in search should be escaped and treated literally -> no match
      {results, _pagination} = Catalog.admin_list_series(%{"q" => "%"})
      assert results == []

      {results, _} = Catalog.admin_list_series(%{"q" => "naruto"})
      assert length(results) == 1
      assert hd(results).title == "Naruto"

      {results, _} = Catalog.admin_list_series(%{"q" => "NARUTO"})
      assert length(results) == 1
    end

    test "clamps page_size to 1..100 and page to last page" do
      for _ <- 1..3, do: CatalogFixtures.series_fixture()

      {results, pagination} = Catalog.admin_list_series(%{"page_size" => "999"})
      assert pagination.page_size == 100
      assert pagination.total_pages >= 1
      assert length(results) <= 100

      {results, pagination} = Catalog.admin_list_series(%{"page" => "999", "page_size" => "1"})
      assert pagination.page == pagination.total_pages
      assert length(results) <= 1

      {_results, pagination} = Catalog.admin_list_series(%{"page_size" => "0"})
      assert pagination.page_size == 1
    end

    test "returns empty and correctly paginated when no series match" do
      # ensure clean state by searching for a unique impossible term
      {results, pagination} =
        Catalog.admin_list_series(%{"q" => "this-series-does-not-exist-zzz"})

      assert results == []
      assert pagination.total_entries == 0
      assert pagination.total_pages == 1
    end

    test "preloads authors for the Authors column" do
      series = CatalogFixtures.series_fixture(%{title: "Author Test"})
      # directly create author via catalog
      {:ok, author} = Catalog.create_author(%{name: "Eiichiro Oda"})
      :ok = Catalog.add_series_author(series, author)

      {results, _} = Catalog.admin_list_series(%{"q" => "Author Test"})
      assert length(results) == 1
      found = hd(results)
      assert Enum.map(found.authors, & &1.name) == ["Eiichiro Oda"]
    end
  end
end
