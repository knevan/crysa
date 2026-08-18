defmodule Crysa.CatalogFixtures do
  @moduledoc """
  Test fixtures for the Catalog context.
  """

  alias Crysa.Catalog
  alias Crysa.Catalog.{Category, Chapter, ChapterImage, Series}

  @spec unique_title() :: String.t()
  def unique_title, do: "Series #{System.unique_integer([:positive])}"

  @spec series_fixture(map()) :: Series.t()
  def series_fixture(attrs \\ %{}) do
    unique = System.unique_integer([:positive])

    defaults = %{
      title: "Series #{unique}",
      slug: "series-#{unique}",
      source_url: "https://example.test/series/#{unique}",
      publication_status: "ongoing",
      processing_status: "available"
    }

    {:ok, series} = Catalog.create_series(Map.merge(defaults, attrs))
    series
  end

  @spec chapter_fixture(Series.t(), map()) :: Chapter.t()
  def chapter_fixture(%Series{} = series, attrs \\ %{}) do
    unique = System.unique_integer([:positive])

    defaults = %{
      series_id: series.id,
      chapter_key: "ch-#{unique}",
      display_number: "1",
      sort_key: String.pad_leading("#{unique}", 6, "0"),
      source_url: "https://example.test/chapter/#{unique}",
      status: "available"
    }

    {:ok, chapter} = Catalog.create_chapter(Map.merge(defaults, attrs))
    chapter
  end

  @spec chapter_image_fixture(Chapter.t(), map()) :: ChapterImage.t()
  def chapter_image_fixture(%Chapter{} = chapter, attrs \\ %{}) do
    unique = System.unique_integer([:positive])

    defaults = %{
      chapter_id: chapter.id,
      image_order: 0,
      source_url: "https://example.test/image/#{unique}.webp",
      width: 800,
      height: 1200,
      byte_size: 50_000
    }

    {:ok, image} = Catalog.create_chapter_image(Map.merge(defaults, attrs))
    image
  end

  @spec category_fixture(String.t()) :: Category.t()
  def category_fixture(name \\ "Action") do
    {:ok, category} = Catalog.get_or_create_category(name)
    category
  end

  @spec categories_fixture([String.t()]) :: [Category.t()]
  def categories_fixture(names), do: Enum.map(names, &category_fixture/1)
end
