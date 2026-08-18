defmodule Crysa.CatalogTest do
  use Crysa.DataCase, async: true

  alias Crysa.Catalog
  alias Crysa.CatalogFixtures

  describe "series" do
    test "create_series/1 normalizes slug and trims text fields" do
      attrs = %{
        title: "  Solo Leveling  ",
        slug: "Solo Leveling",
        source_url: "  https://example.test/series/solo  ",
        publication_status: "ongoing",
        processing_status: "available"
      }

      assert {:ok, series} = Catalog.create_series(attrs)
      assert series.title == "Solo Leveling"
      assert series.slug == "solo-leveling"
      assert series.source_url == "https://example.test/series/solo"
      assert series.chapter_count == 0
    end

    test "create_series/1 rejects invalid publication status" do
      assert {:error, changeset} =
               Catalog.create_series(%{
                 title: "Invalid",
                 slug: "invalid",
                 source_url: "https://example.test/series/invalid",
                 publication_status: "cancelled",
                 processing_status: "available"
               })

      assert errors_on(changeset) |> Map.has_key?(:publication_status)
    end

    test "create_series/1 enforces unique source_url" do
      series = CatalogFixtures.series_fixture()

      assert {:error, changeset} =
               Catalog.create_series(%{
                 title: "Duplicate",
                 slug: "duplicate",
                 source_url: series.source_url
               })

      assert {"has already been taken", _} = changeset.errors[:source_url]
    end

    test "update_series/2 allows partial updates without source_url" do
      series = CatalogFixtures.series_fixture()

      assert {:ok, updated} =
               Catalog.update_series(series, %{title: "Renamed", description: "Hi"})

      assert updated.title == "Renamed"
      assert updated.description == "Hi"
      assert updated.source_url == series.source_url
    end

    test "delete_series/1 removes the series" do
      series = CatalogFixtures.series_fixture()

      assert {:ok, _deleted} = Catalog.delete_series(series)
      assert Catalog.get_series(series.id) == nil
    end

    test "get_series_by_slug/1 preloads categories and authors" do
      series = CatalogFixtures.series_fixture()
      category = CatalogFixtures.category_fixture("Action")

      assert {:ok, _} = Catalog.set_series_categories(series, [category])

      found = Catalog.get_series_by_slug(series.slug)
      assert found.id == series.id
      assert Enum.map(found.categories, & &1.id) == [category.id]
    end
  end

  describe "chapters" do
    test "create_chapter/1 persists canonical chapter identity" do
      series = CatalogFixtures.series_fixture()

      assert {:ok, chapter} =
               Catalog.create_chapter(%{
                 series_id: series.id,
                 chapter_key: "10-2",
                 display_number: "10 Part 2",
                 sort_key: "000010-000002",
                 source_url: "https://example.test/chapter/10-2",
                 status: "pending"
               })

      assert chapter.chapter_key == "10-2"
      assert chapter.status == "pending"
    end

    test "create_chapter/1 rejects duplicate chapter_key within a series" do
      series = CatalogFixtures.series_fixture()
      chapter = CatalogFixtures.chapter_fixture(series)

      assert {:error, changeset} =
               Catalog.create_chapter(%{
                 series_id: series.id,
                 chapter_key: chapter.chapter_key,
                 display_number: "copy",
                 sort_key: "000002",
                 source_url: "https://example.test/chapter/other"
               })

      assert {"has already been taken", _} = changeset.errors[:series_id]
    end

    test "create_chapter/1 allows the same chapter_key across different series" do
      series_a = CatalogFixtures.series_fixture()
      series_b = CatalogFixtures.series_fixture()

      assert {:ok, _} =
               Catalog.create_chapter(%{
                 series_id: series_a.id,
                 chapter_key: "5",
                 display_number: "5",
                 sort_key: "000005",
                 source_url: "https://example.test/a/5"
               })

      assert {:ok, _} =
               Catalog.create_chapter(%{
                 series_id: series_b.id,
                 chapter_key: "5",
                 display_number: "5",
                 sort_key: "000005",
                 source_url: "https://example.test/b/5"
               })
    end

    test "update_chapter/2 allows worker state transitions" do
      series = CatalogFixtures.series_fixture()
      chapter = CatalogFixtures.chapter_fixture(series)

      assert {:ok, updated} =
               Catalog.update_chapter(chapter, %{
                 status: "error",
                 retry_count: 1,
                 last_error: "boom"
               })

      assert updated.status == "error"
      assert updated.retry_count == 1
      assert updated.last_error == "boom"
    end

    test "delete_chapter/1 removes the chapter" do
      series = CatalogFixtures.series_fixture()
      chapter = CatalogFixtures.chapter_fixture(series)

      assert {:ok, _} = Catalog.delete_chapter(chapter)
      assert Catalog.get_chapter(chapter.id) == nil
    end
  end

  describe "chapter images" do
    test "create_chapter_image/1 persists ordered image metadata" do
      series = CatalogFixtures.series_fixture()
      chapter = CatalogFixtures.chapter_fixture(series)

      assert {:ok, image} =
               Catalog.create_chapter_image(%{
                 chapter_id: chapter.id,
                 image_order: 0,
                 source_url: "https://example.test/images/1.webp"
               })

      assert image.image_order == 0
    end

    test "create_chapter_image/1 rejects duplicate image order per chapter" do
      series = CatalogFixtures.series_fixture()
      chapter = CatalogFixtures.chapter_fixture(series)
      CatalogFixtures.chapter_image_fixture(chapter, %{image_order: 0})

      assert {:error, changeset} =
               Catalog.create_chapter_image(%{
                 chapter_id: chapter.id,
                 image_order: 0,
                 source_url: "https://example.test/images/dup.webp"
               })

      assert {"has already been taken", _} = changeset.errors[:chapter_id]
    end

    test "create_chapter_image/1 allows the same order in different chapters" do
      series = CatalogFixtures.series_fixture()
      chapter_a = CatalogFixtures.chapter_fixture(series, %{chapter_key: "1"})
      chapter_b = CatalogFixtures.chapter_fixture(series, %{chapter_key: "2"})

      assert {:ok, _} = Catalog.create_chapter_image(%{chapter_id: chapter_a.id, image_order: 0})
      assert {:ok, _} = Catalog.create_chapter_image(%{chapter_id: chapter_b.id, image_order: 0})
    end
  end

  describe "categories and authors" do
    test "create_category/1 normalizes the name" do
      assert {:ok, category} = Catalog.create_category(%{name: "  Action   Comedy "})
      assert category.name == "Action   Comedy"
      assert category.normalized_name == "action comedy"
    end

    test "create_category/1 enforces case-insensitive uniqueness" do
      assert {:ok, _} = Catalog.create_category(%{name: "Action"})
      assert {:error, changeset} = Catalog.create_category(%{name: "action"})
      assert {"has already been taken", _} = changeset.errors[:normalized_name]
    end

    test "get_or_create_category/1 reuses an existing normalized category" do
      assert {:ok, category} = Catalog.get_or_create_category("Drama")
      assert {:ok, same} = Catalog.get_or_create_category("  DRAMA ")
      assert category.id == same.id
    end

    test "get_or_create_author/1 reuses an existing normalized author" do
      assert {:ok, author} = Catalog.get_or_create_author("Togashi")
      assert {:ok, same} = Catalog.get_or_create_author("togashi")
      assert author.id == same.id
    end

    test "update_category/2 re-normalizes on rename" do
      assert {:ok, category} = Catalog.create_category(%{name: "Action"})

      assert {:ok, updated} = Catalog.update_category(category, %{name: "Adventure"})
      assert updated.name == "Adventure"
      assert updated.normalized_name == "adventure"
    end

    test "delete_category/1 removes the category" do
      assert {:ok, category} = Catalog.create_category(%{name: "Slice of Life"})
      assert {:ok, _} = Catalog.delete_category(category)
      assert Catalog.get_category(category.id) == nil
    end
  end

  describe "series associations" do
    test "set_series_categories/2 replaces the full category set" do
      series = CatalogFixtures.series_fixture()
      [action, drama] = CatalogFixtures.categories_fixture(["Action", "Drama"])
      comedy = CatalogFixtures.category_fixture("Comedy")

      assert {:ok, _} = Catalog.set_series_categories(series, [action, drama])
      assert {:ok, _} = Catalog.set_series_categories(series, [comedy])

      found = Catalog.get_series_by_slug(series.slug)
      assert Enum.map(found.categories, & &1.id) == [comedy.id]
    end

    test "add/remove series category are idempotent" do
      series = CatalogFixtures.series_fixture()
      category = CatalogFixtures.category_fixture("Horror")

      assert :ok = Catalog.add_series_category(series, category)
      assert :ok = Catalog.add_series_category(series, category)
      assert :ok = Catalog.remove_series_category(series, category)
      assert :ok = Catalog.remove_series_category(series, category)

      found = Catalog.get_series_by_slug(series.slug)
      assert found.categories == []
    end

    test "add/remove series author are idempotent" do
      series = CatalogFixtures.series_fixture()

      {:ok, author} = Catalog.get_or_create_author("Eiichiro Oda")
      assert :ok = Catalog.add_series_author(series, author)
      assert :ok = Catalog.add_series_author(series, author)
      assert :ok = Catalog.remove_series_author(series, author)

      found = Catalog.get_series_by_slug(series.slug)
      assert found.authors == []
    end
  end
end
