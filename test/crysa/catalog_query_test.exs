defmodule Crysa.CatalogQueryTest do
  use Crysa.DataCase, async: true

  import Ecto.Changeset

  alias Crysa.Catalog
  alias Crysa.Catalog.Series
  alias Crysa.CatalogFixtures
  alias Crysa.Repo

  describe "list_new_series/1" do
    test "orders by insertion date descending with id tie-breaker" do
      old = CatalogFixtures.series_fixture()
      new = CatalogFixtures.series_fixture()

      backdate(old)

      {series, pagination} = Catalog.list_new_series()

      assert Enum.map(series, & &1.id) == [new.id, old.id]
      assert pagination.total_entries == 2
      assert pagination.total_pages == 1
    end

    test "clamps page and page_size inputs" do
      for _ <- 1..30, do: CatalogFixtures.series_fixture()

      {_series, pagination} = Catalog.list_new_series(%{"page" => "0", "page_size" => "1000"})
      assert pagination.page == 1
      assert pagination.page_size == 60
      assert pagination.total_entries == 30
      assert pagination.total_pages == 1
    end

    test "clamps a page beyond the result set to the last page" do
      for _ <- 1..5, do: CatalogFixtures.series_fixture()

      {series, pagination} = Catalog.list_new_series(%{"page" => "10"})
      assert [_, _, _, _, _] = series
      assert pagination.page == 1
      assert pagination.total_entries == 5
    end
  end

  describe "list_most_viewed/1" do
    test "orders by view count descending with id tie-breaker" do
      low = CatalogFixtures.series_fixture(%{view_count: 1})
      high = CatalogFixtures.series_fixture(%{view_count: 100})

      {series, _} = Catalog.list_most_viewed()
      assert Enum.map(series, & &1.id) == [high.id, low.id]
    end

    test "keeps stable order when view counts are equal" do
      a = CatalogFixtures.series_fixture(%{view_count: 5})
      b = CatalogFixtures.series_fixture(%{view_count: 5})
      c = CatalogFixtures.series_fixture(%{view_count: 5})

      {series, _} = Catalog.list_most_viewed()
      assert Enum.map(series, & &1.id) == [c.id, b.id, a.id]
    end
  end

  describe "list_latest_updates/1" do
    test "orders by last chapter date descending with nulls last" do
      no_chapters = CatalogFixtures.series_fixture()
      old_update = CatalogFixtures.series_fixture()
      new_update = CatalogFixtures.series_fixture()

      set_last_chapter_at(old_update, ~U[2026-01-01 00:00:00.000000Z])
      set_last_chapter_at(new_update, ~U[2026-02-01 00:00:00.000000Z])

      {series, _} = Catalog.list_latest_updates()

      assert Enum.map(series, & &1.id) == [new_update.id, old_update.id, no_chapters.id]
    end
  end

  describe "browse_series/1 category filters" do
    setup do
      series_a = CatalogFixtures.series_fixture()
      series_b = CatalogFixtures.series_fixture()
      series_c = CatalogFixtures.series_fixture()

      [action, drama, romance] =
        CatalogFixtures.categories_fixture(["Action", "Drama", "Romance"])

      {:ok, _} = Catalog.set_series_categories(series_a, [action])
      {:ok, _} = Catalog.set_series_categories(series_b, [action, drama])
      {:ok, _} = Catalog.set_series_categories(series_c, [romance])

      %{series_a: series_a, series_b: series_b, series_c: series_c}
    end

    test "includes series matching any selected category", %{
      series_a: series_a,
      series_b: series_b
    } do
      {series, _} = Catalog.browse_series(%{"category" => "action"})
      assert Enum.map(series, & &1.id) |> Enum.sort() == [series_a.id, series_b.id]
    end

    test "accepts multiple categories and matches any of them",
         %{series_a: series_a, series_b: series_b, series_c: series_c} do
      {series, _} = Catalog.browse_series(%{"category" => "action,romance"})
      assert Enum.map(series, & &1.id) |> Enum.sort() == [series_a.id, series_b.id, series_c.id]
    end

    test "is case-insensitive and trims category names", %{series_a: series_a, series_b: series_b} do
      {series, _} = Catalog.browse_series(%{"category" => "  ACTION "})
      assert Enum.map(series, & &1.id) |> Enum.sort() == [series_a.id, series_b.id]
    end

    test "excludes series matching any selected category", %{
      series_a: series_a,
      series_b: series_b,
      series_c: series_c
    } do
      {series, _} = Catalog.browse_series(%{"exclude_category" => "action"})
      assert Enum.map(series, & &1.id) == [series_c.id]

      {series, _} = Catalog.browse_series(%{"exclude_category" => "romance"})
      assert Enum.map(series, & &1.id) |> Enum.sort() == [series_a.id, series_b.id]
    end

    test "combines include and exclude filters", %{series_a: series_a} do
      {series, _} =
        Catalog.browse_series(%{"category" => "action", "exclude_category" => "drama"})

      assert Enum.map(series, & &1.id) == [series_a.id]
    end

    test "normalizes internal whitespace in category names", %{series_a: series_a} do
      comedy = CatalogFixtures.category_fixture("Action Comedy")
      {:ok, _} = Catalog.set_series_categories(series_a, [comedy])

      {series, _} = Catalog.browse_series(%{"category" => "Action   Comedy"})
      assert Enum.map(series, & &1.id) == [series_a.id]
    end
  end

  describe "browse_series/1 status filter" do
    test "only returns series with the requested publication status" do
      ongoing = CatalogFixtures.series_fixture(%{publication_status: "ongoing"})
      completed = CatalogFixtures.series_fixture(%{publication_status: "completed"})

      {series, _} = Catalog.browse_series(%{"publication_status" => "completed"})
      assert Enum.map(series, & &1.id) == [completed.id]

      {series, _} = Catalog.browse_series(%{"publication_status" => "ongoing"})
      assert Enum.map(series, & &1.id) == [ongoing.id]

      {series, _} = Catalog.browse_series(%{"publication_status" => "not-a-status"})
      assert [_, _] = series
    end
  end

  describe "browse_series/1 search" do
    test "matches titles case-insensitively with substring semantics" do
      one_piece = CatalogFixtures.series_fixture(%{title: "One Piece"})
      CatalogFixtures.series_fixture(%{title: "Naruto"})

      {series, _} = Catalog.browse_series(%{"q" => "one pie"})
      assert Enum.map(series, & &1.id) == [one_piece.id]

      {series, _} = Catalog.browse_series(%{"q" => "ONE PIECE"})
      assert Enum.map(series, & &1.id) == [one_piece.id]
    end

    test "ranks results by pg_trgm similarity" do
      one_piece = CatalogFixtures.series_fixture(%{title: "One Piece"})
      lesser = CatalogFixtures.series_fixture(%{title: "One Piece of Manga"})

      {series, _} = Catalog.browse_series(%{"q" => "one piece"})
      assert Enum.map(series, & &1.id) == [one_piece.id, lesser.id]
    end

    test "treats LIKE wildcards in the search term literally" do
      literal = CatalogFixtures.series_fixture(%{title: "100% Real Manga"})
      decoy = CatalogFixtures.series_fixture(%{title: "100x Real Manga"})

      {series, _} = Catalog.browse_series(%{"q" => "100%"})
      assert Enum.map(series, & &1.id) == [literal.id]
      refute Enum.map(series, & &1.id) |> Enum.member?(decoy.id)

      literal_underscore = CatalogFixtures.series_fixture(%{title: "Cat_House"})
      decoy_underscore = CatalogFixtures.series_fixture(%{title: "CatXHouse"})

      {series, _} = Catalog.browse_series(%{"q" => "cat_house"})
      assert Enum.map(series, & &1.id) == [literal_underscore.id]
      refute Enum.map(series, & &1.id) |> Enum.member?(decoy_underscore.id)
    end

    test "ignores empty and overlong search terms" do
      series = CatalogFixtures.series_fixture(%{title: "Berserk"})

      {series_all, _} = Catalog.browse_series(%{"q" => "   "})
      assert Enum.map(series_all, & &1.id) == [series.id]

      long_term = String.duplicate("a", 500)
      {series_long, _} = Catalog.browse_series(%{"q" => long_term})
      assert series_long == []
    end

    test "escape_like/1 escapes backslashes, percent and underscores" do
      assert Catalog.Query.escape_like("100% off_5\\x") == "100\\% off\\_5\\\\x"
    end
  end

  describe "pagination stability" do
    test "boundary pages contain no duplicates and cover the full set" do
      ids =
        for _ <- 1..7 do
          CatalogFixtures.series_fixture().id
        end
        |> Enum.reverse()

      {page1, p1} = Catalog.browse_series(%{"page" => "1", "page_size" => "3"})
      {page2, p2} = Catalog.browse_series(%{"page" => "2", "page_size" => "3"})
      {page3, p3} = Catalog.browse_series(%{"page" => "3", "page_size" => "3"})

      assert p1.page_size == 3
      assert p2.page == 2
      assert p3.page == 3

      collected = Enum.map(page1, & &1.id) ++ Enum.map(page2, & &1.id) ++ Enum.map(page3, & &1.id)
      assert Enum.uniq(collected) == collected
      assert Enum.sort(collected) == Enum.sort(ids)
    end

    test "page_size is clamped to the upper bound" do
      for _ <- 1..70, do: CatalogFixtures.series_fixture()

      {series, pagination} = Catalog.browse_series(%{"page_size" => "100"})
      assert Enum.count_until(series, 61) == 60
      assert pagination.page_size == 60
    end

    test "a huge page is clamped to the last page" do
      for _ <- 1..7, do: CatalogFixtures.series_fixture()

      {series, pagination} = Catalog.browse_series(%{"page" => "999", "page_size" => "2"})
      assert [_] = series
      assert pagination.page == 4
      assert pagination.total_pages == 4
    end

    test "invalid page inputs fall back to defaults" do
      for _ <- 1..3, do: CatalogFixtures.series_fixture()

      {series, pagination} = Catalog.browse_series(%{"page" => "abc", "page_size" => "xyz"})
      assert pagination.page == 1
      assert pagination.page_size == 24
      assert [_, _, _] = series
    end
  end

  describe "chapter queries" do
    test "list_chapters/2 orders by sort_key descending and paginates" do
      series = CatalogFixtures.series_fixture()

      for n <- 1..5 do
        CatalogFixtures.chapter_fixture(series, %{
          chapter_key: "ch-#{n}",
          display_number: "#{n}",
          sort_key: String.pad_leading("#{n}", 6, "0")
        })
      end

      {chapters, pagination} =
        Catalog.list_chapters(series.id, %{"page" => "1", "page_size" => "2"})

      assert Enum.map(chapters, & &1.display_number) == ["5", "4"]
      assert pagination.total_entries == 5
      assert pagination.total_pages == 3
    end

    test "get_latest_chapter/1 returns the highest sort_key chapter" do
      series = CatalogFixtures.series_fixture()

      CatalogFixtures.chapter_fixture(series, %{
        chapter_key: "1",
        sort_key: "000001",
        source_url: "https://example.test/c/1"
      })

      latest = CatalogFixtures.chapter_fixture(series, %{chapter_key: "2", sort_key: "000002"})

      assert Catalog.get_latest_chapter(series.id).id == latest.id
    end

    test "get_reader_chapter/2 loads images in order and is series-scoped" do
      series = CatalogFixtures.series_fixture()
      chapter = CatalogFixtures.chapter_fixture(series, %{chapter_key: "1", sort_key: "000001"})

      image_b = CatalogFixtures.chapter_image_fixture(chapter, %{image_order: 1})
      image_a = CatalogFixtures.chapter_image_fixture(chapter, %{image_order: 0})

      other = CatalogFixtures.series_fixture()
      CatalogFixtures.chapter_fixture(other, %{chapter_key: "1", sort_key: "000001"})

      assert Catalog.get_reader_chapter(series.id, "1").images |> Enum.map(& &1.id) == [
               image_a.id,
               image_b.id
             ]

      assert Catalog.get_reader_chapter(other.id, "1").id != chapter.id
      assert Catalog.get_reader_chapter(series.id, "missing") == nil
    end

    test "chapter_navigation/2 returns prev and next neighbors" do
      series = CatalogFixtures.series_fixture()

      first = CatalogFixtures.chapter_fixture(series, %{chapter_key: "1", sort_key: "000001"})
      middle = CatalogFixtures.chapter_fixture(series, %{chapter_key: "2", sort_key: "000002"})
      last = CatalogFixtures.chapter_fixture(series, %{chapter_key: "3", sort_key: "000003"})

      assert {nil, next} = Catalog.chapter_navigation(series.id, first.chapter_key)
      assert next.chapter_key == middle.chapter_key

      assert {prev, next} = Catalog.chapter_navigation(series.id, middle.chapter_key)
      assert prev.chapter_key == first.chapter_key
      assert next.chapter_key == last.chapter_key

      assert {prev, nil} = Catalog.chapter_navigation(series.id, last.chapter_key)
      assert prev.chapter_key == middle.chapter_key

      assert {nil, nil} = Catalog.chapter_navigation(series.id, "missing")
    end
  end

  describe "list_categories_with_counts/0" do
    test "returns only categories with series and their counts" do
      empty = CatalogFixtures.category_fixture("Unused")

      series = CatalogFixtures.series_fixture()
      [action, drama] = CatalogFixtures.categories_fixture(["Action", "Drama"])
      {:ok, _} = Catalog.set_series_categories(series, [action, drama])

      series2 = CatalogFixtures.series_fixture()
      {:ok, _} = Catalog.set_series_categories(series2, [action])

      categories = Catalog.list_categories_with_counts()

      assert {_found, 2} = Enum.find(categories, fn {c, _} -> c.id == action.id end)
      assert {_found, 1} = Enum.find(categories, fn {c, _} -> c.id == drama.id end)
      refute Enum.any?(categories, fn {c, _} -> c.id == empty.id end)
    end
  end

  defp backdate(%Series{} = series) do
    set_field(series, :inserted_at, ~U[2025-01-01 00:00:00.000000Z])
  end

  defp set_last_chapter_at(%Series{} = series, datetime) do
    set_field(series, :last_chapter_at, datetime)
  end

  defp set_field(%Series{} = series, field, value) do
    series
    |> change()
    |> force_change(field, value)
    |> Repo.update!()
  end
end
