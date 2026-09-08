defmodule Crysa.CatalogChapterVisibilityTest do
  @moduledoc false

  # Unreadable chapters (anything but `available`) must never leak into
  # public read paths: lists, latest badge, reader, or prev/next
  # navigation. Admin paths intentionally keep full visibility.
  use Crysa.DataCase, async: true

  import Crysa.CatalogFixtures

  alias Crysa.Catalog

  setup do
    series = series_fixture()

    read =
      chapter_fixture(series, %{
        chapter_key: "9",
        display_number: "9",
        sort_key: "000009.000."
      })

    pending =
      chapter_fixture(series, %{
        chapter_key: "10",
        display_number: "10",
        sort_key: "000010.000.",
        status: "pending"
      })

    %{series: series, read: read, pending: pending}
  end

  test "list_chapters/2 hides non-available chapters when filtered", %{
    series: series,
    read: read,
    pending: pending
  } do
    {chapters, _} = Catalog.list_chapters(series.id, %{"status" => "available"})
    assert Enum.map(chapters, & &1.id) == [read.id]

    # Explicit user-supplied statuses other than available still work as
    # a filter (admin-style inspection), but unknown values are ignored.
    {all, _} = Catalog.list_chapters(series.id, %{})
    assert Enum.map(all, & &1.id) |> Enum.sort() == Enum.sort([read.id, pending.id])

    {all_again, _} = Catalog.list_chapters(series.id, %{"status" => "bogus"})
    assert Enum.map(all_again, & &1.id) |> Enum.sort() == Enum.sort([read.id, pending.id])
  end

  test "get_latest_chapter/1 skips pending chapters", %{series: series, read: read} do
    assert Catalog.get_latest_chapter(series.id).id == read.id
  end

  test "get_reader_chapter/2 returns nil for pending chapters", %{
    series: series,
    read: read,
    pending: pending
  } do
    assert Catalog.get_reader_chapter(series.id, read.chapter_key).id == read.id
    assert Catalog.get_reader_chapter(series.id, pending.chapter_key) == nil
  end

  test "chapter_navigation/2 skips pending neighbors", %{series: series} do
    older =
      chapter_fixture(series, %{
        chapter_key: "8",
        display_number: "8",
        sort_key: "000008.000."
      })

    assert {prev, nil} = Catalog.chapter_navigation(series.id, "9")
    assert prev.chapter_key == older.chapter_key
  end
end
