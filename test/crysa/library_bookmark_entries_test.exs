defmodule Crysa.LibraryBookmarkEntriesTest do
  @moduledoc """
  Covers the enriched bookmark library query backing the bookmark page.
  """

  use Crysa.DataCase, async: false

  alias Crysa.AccountsFixtures
  alias Crysa.CatalogFixtures
  alias Crysa.Library

  test "entries carry series, bookmark, and latest available chapter" do
    user = AccountsFixtures.user_fixture()
    series = CatalogFixtures.series_fixture()
    chapter = CatalogFixtures.chapter_fixture(series, %{display_number: "48"})

    assert {:ok, _} = Library.bookmark_series(user, series)

    assert {[entry], pagination} = Library.list_user_bookmark_entries(user, %{})
    assert pagination.total_entries == 1
    assert entry.series.id == series.id
    assert entry.bookmark.user_id == user.id
    assert entry.latest_chapter.id == chapter.id
  end

  test "status filter only returns matching publication status" do
    user = AccountsFixtures.user_fixture()
    ongoing = CatalogFixtures.series_fixture(%{publication_status: "ongoing"})
    completed = CatalogFixtures.series_fixture(%{publication_status: "completed"})

    assert {:ok, _} = Library.bookmark_series(user, ongoing)
    assert {:ok, _} = Library.bookmark_series(user, completed)

    assert {[entry], _} = Library.list_user_bookmark_entries(user, %{"status" => "completed"})
    assert entry.series.id == completed.id

    # Unknown status means no filter.
    assert {entries, pagination} =
             Library.list_user_bookmark_entries(user, %{"status" => "bogus"})

    assert pagination.total_entries == 2
    assert length(entries) == 2
  end

  test "title sort orders alphabetically and tolerates bad input" do
    user = AccountsFixtures.user_fixture()
    beta = CatalogFixtures.series_fixture(%{title: "Beta"})
    alpha = CatalogFixtures.series_fixture(%{title: "Alpha"})

    assert {:ok, _} = Library.bookmark_series(user, beta)
    assert {:ok, _} = Library.bookmark_series(user, alpha)

    assert {entries, _} =
             Library.list_user_bookmark_entries(user, %{
               "sort_by" => "title",
               "order" => "asc"
             })

    assert Enum.map(entries, & &1.series.id) == [alpha.id, beta.id]

    # Malformed sort/order fall back to safe defaults instead of raising.
    assert {_, pagination} =
             Library.list_user_bookmark_entries(user, %{
               "sort_by" => "nope",
               "order" => "sideways"
             })

    assert pagination.page == 1
  end

  test "archived series are hidden from the library" do
    user = AccountsFixtures.user_fixture()
    series = CatalogFixtures.series_fixture()
    assert {:ok, _} = Library.bookmark_series(user, series)
    assert {:ok, _} = Crysa.Catalog.archive_series(series)

    assert {[], pagination} = Library.list_user_bookmark_entries(user, %{})
    assert pagination.total_entries == 0
  end

  describe "reading progress" do
    test "recording creates one row per user and series" do
      user = AccountsFixtures.user_fixture()
      series = CatalogFixtures.series_fixture()
      chapter = CatalogFixtures.chapter_fixture(series, %{display_number: "10"})

      assert {:ok, progress} = Library.record_reading_progress(user, series, chapter)
      assert progress.user_id == user.id
      assert progress.series_id == series.id
      assert progress.last_chapter_id == chapter.id
      assert %Crysa.Library.ReadingProgress{} = Library.get_reading_progress(user, series)
    end

    test "recording again updates the same row instead of duplicating" do
      user = AccountsFixtures.user_fixture()
      series = CatalogFixtures.series_fixture()
      old = CatalogFixtures.chapter_fixture(series, %{display_number: "10", sort_key: "000010"})
      new = CatalogFixtures.chapter_fixture(series, %{display_number: "18", sort_key: "000018"})

      assert {:ok, first} = Library.record_reading_progress(user, series, old)
      assert {:ok, second} = Library.record_reading_progress(user, series, new)

      assert first.id == second.id
      assert second.last_chapter_id == new.id

      import Ecto.Query

      assert Crysa.Repo.aggregate(
               from(p in Crysa.Library.ReadingProgress,
                 where: p.user_id == ^user.id and p.series_id == ^series.id
               ),
               :count,
               :id
             ) == 1
    end

    test "entries carry the last read chapter" do
      user = AccountsFixtures.user_fixture()
      series = CatalogFixtures.series_fixture()

      read =
        CatalogFixtures.chapter_fixture(series, %{display_number: "10", sort_key: "000010"})

      latest =
        CatalogFixtures.chapter_fixture(series, %{display_number: "18", sort_key: "000018"})

      assert {:ok, _} = Library.bookmark_series(user, series)

      assert {[before], _} = Library.list_user_bookmark_entries(user, %{})
      assert before.last_read_chapter == nil

      assert {:ok, _} = Library.record_reading_progress(user, series, read)

      assert {[entry], _} = Library.list_user_bookmark_entries(user, %{})
      assert entry.latest_chapter.id == latest.id
      assert entry.last_read_chapter.display_number == "10"
    end
  end
end
