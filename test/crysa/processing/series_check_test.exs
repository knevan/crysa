defmodule Crysa.Processing.SeriesCheckTest do
  @moduledoc false

  use Crysa.DataCase, async: true

  import Crysa.CatalogFixtures
  import Crysa.ScrapingFixtures

  alias Crysa.Catalog
  alias Crysa.Processing.SeriesCheck

  setup do
    %{site: site} = published_site_fixture()
    series = series_fixture(%{source_url: "https://#{site.host}/series/abc"})

    snapshot = %{
      config: config_for(site.host),
      version: 1
    }

    %{series: series, snapshot: snapshot}
  end

  defp config_for(_host) do
    {:ok, config} =
      Crysa.Scraping.Config.build(%{
        "selectors" => %{
          "chapter_link" => ".chapter-list a",
          "image_on_chapter_page" => "#reader img"
        },
        "chapter_order" => "desc"
      })

    config
  end

  defp page_html(chapters) do
    links =
      Enum.map_join(chapters, "\n", fn key -> ~s(<a href="/ch-#{key}">Chapter #{key}</a>) end)

    """
    <html><body><div class="chapter-list">#{links}</div></body></html>
    """
  end

  describe "run/3" do
    test "full scan inserts new chapters and enqueues downloads", %{
      series: series,
      snapshot: snapshot
    } do
      html = page_html([105, 104, 10.5])

      assert {:ok, {:enqueued, 3}} =
               SeriesCheck.run(series, snapshot,
                 fetch_html: fn _url -> {:ok, html} end,
                 enqueue?: false
               )

      chapters = Catalog.list_chapters(series.id) |> elem(0)
      keys = Enum.map(chapters, & &1.chapter_key)
      assert Enum.sort(keys) == ["10.5", "104", "105"]

      sorted = Enum.sort_by(chapters, & &1.sort_key)
      assert Enum.map(sorted, & &1.sort_key) == ["000010.005.", "000104.000.", "000105.000."]
    end

    test "is idempotent: rerunning does not duplicate chapters", %{
      series: series,
      snapshot: snapshot
    } do
      html = page_html([105])

      opts = [fetch_html: fn _url -> {:ok, html} end, enqueue?: false]
      assert {:ok, {:enqueued, 1}} = SeriesCheck.run(series, snapshot, opts)

      # Second run: quick check passes and counts match → nothing to do.
      assert {:ok, :up_to_date} = SeriesCheck.run(series, snapshot, opts)

      {chapters, _} = Catalog.list_chapters(series.id)
      assert [_] = chapters
    end

    test "quick check passes when up to date (no full scan)", %{
      series: series,
      snapshot: snapshot
    } do
      {:ok, _} =
        Catalog.create_chapter(%{
          series_id: series.id,
          chapter_key: "105",
          display_number: "105",
          sort_key: "000105.000.",
          source_url: "https://x.test/ch-105",
          status: "available"
        })

      html = page_html([105])
      fetched = :counters.new(1, [:atomics])

      fetch = fn url ->
        :counters.add(fetched, 1, 1)
        {:ok, if(String.contains?(url, "?page="), do: "<html></html>", else: html)}
      end

      assert {:ok, :up_to_date} =
               SeriesCheck.run(series, snapshot, fetch_html: fetch, enqueue?: false)

      assert :counters.get(fetched, 1) == 1
    end

    test "count mismatch triggers a full scan that backfills missing chapters", %{
      series: series,
      snapshot: snapshot
    } do
      {:ok, _} =
        Catalog.create_chapter(%{
          series_id: series.id,
          chapter_key: "105",
          display_number: "105",
          sort_key: "000105.000.",
          source_url: "https://x.test/ch-105",
          status: "available"
        })

      # Site shows two chapters; DB has one → count mismatch → scan inserts 104.
      html = page_html([105, 104])

      assert {:ok, {:enqueued, 1}} =
               SeriesCheck.run(series, snapshot,
                 fetch_html: fn _ -> {:ok, html} end,
                 enqueue?: false
               )

      {chapters, _} = Catalog.list_chapters(series.id)
      assert [_a, _b] = chapters
    end

    test "count check ignores non-chapter selector matches (P7-6)", %{
      series: series,
      snapshot: snapshot
    } do
      # DB has exactly the one real chapter; the page also contains a nav link
      # matched by a loose selector that fails chapter extraction.
      {:ok, _} =
        Catalog.create_chapter(%{
          series_id: series.id,
          chapter_key: "105",
          display_number: "105",
          sort_key: "000105.000.",
          source_url: "https://x.test/ch-105",
          status: "available"
        })

      html = """
      <html><body><div class="chapter-list">
        <a href="/ch-105">Chapter 105</a>
        <a href="https://cdn.example.test/tracking.gif" width="1" height="1"></a>
      </div></body></html>
      """

      fetched = :counters.new(1, [:atomics])

      fetch = fn _url ->
        :counters.add(fetched, 1, 1)
        {:ok, html}
      end

      assert {:ok, :up_to_date} =
               SeriesCheck.run(series, snapshot, fetch_html: fetch, enqueue?: false)

      # Only the initial series-page fetch happened; no full-scan pages.
      assert :counters.get(fetched, 1) == 1
    end

    test "no chapters found on an empty page", %{series: series, snapshot: snapshot} do
      assert {:ok, :no_chapters_found} =
               SeriesCheck.run(series, snapshot,
                 fetch_html: fn _ -> {:ok, "<html><body></body></html>"} end,
                 enqueue?: false
               )
    end

    test "fetch failures return tagged errors", %{series: series, snapshot: snapshot} do
      assert {:error, {:fetch_failed, reason}} =
               SeriesCheck.run(series, snapshot,
                 fetch_html: fn _ -> {:error, :timeout} end,
                 enqueue?: false
               )

      assert reason == :timeout
    end
  end

  describe "full_scan pagination stop conditions" do
    test "stops at an empty page", %{series: series, snapshot: snapshot} do
      html = page_html([5])
      page2 = "<html><body><div class=\"chapter-list\"></div></body></html>"

      fetch = fn url ->
        if String.contains?(url, "page=2"), do: {:ok, page2}, else: {:ok, html}
      end

      candidates = SeriesCheck.full_scan(parse!(html), series, fetch, snapshot.config)
      assert [_] = candidates
    end

    test "stops when a page adds no new chapter keys (looping pagination)", %{series: series} do
      html = page_html([5])
      fetched = :counters.new(1, [:atomics])

      fetch = fn _url ->
        :counters.add(fetched, 1, 1)
        {:ok, html}
      end

      cfg = paginated_config()
      candidates = SeriesCheck.full_scan(parse!(html), series, fetch, cfg)

      assert [_] = candidates
      # First page is pre-parsed; only the duplicate second page is fetched.
      assert :counters.get(fetched, 1) == 1
    end

    defp paginated_config do
      {:ok, config} =
        Crysa.Scraping.Config.build(%{
          "selectors" => %{
            "chapter_link" => ".chapter-list a",
            "image_on_chapter_page" => "#reader img"
          },
          "pagination" => %{"type" => "query_param", "param" => "page", "max_pages" => 10}
        })

      config
    end

    defp parse!(html) do
      {:ok, doc} = Floki.parse_document(html)
      doc
    end
  end
end
