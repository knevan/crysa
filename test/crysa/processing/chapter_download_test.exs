defmodule Crysa.Processing.ChapterDownloadTest do
  @moduledoc false

  use Crysa.DataCase, async: true

  import Crysa.CatalogFixtures
  import Crysa.ScrapingFixtures

  alias Crysa.Catalog
  alias Crysa.Processing.ChapterDownload

  setup do
    %{site: site} = published_site_fixture()
    series = series_fixture(%{source_url: "https://#{site.host}/series/abc"})

    chapter =
      chapter_fixture(series, %{
        chapter_key: "12",
        display_number: "12",
        sort_key: "000012.000.",
        source_url: "https://#{site.host}/ch-12",
        status: "pending"
      })

    snapshot = %{config: config_for(), version: 1}

    %{series: series, chapter: chapter, snapshot: snapshot}
  end

  defp config_for do
    {:ok, config} =
      Crysa.Scraping.Config.build(%{
        "selectors" => %{
          "chapter_link" => ".chapter-list a",
          "image_on_chapter_page" => "#reader img"
        }
      })

    config
  end

  defp page_html do
    """
    <html><body><div id="reader">
      <img data-src="https://cdn.example.test/p1.webp"/>
      <img src="https://cdn.example.test/p2.webp"/>
    </div></body></html>
    """
  end

  defp deps(opts \\ []) do
    %{
      fetch_html: Keyword.get(opts, :fetch_html, fn _url, _o -> {:ok, page_html()} end),
      fetch_bytes:
        Keyword.get(opts, :fetch_bytes, fn url, _o -> {:ok, <<"img:", url::binary>>} end),
      encode: Keyword.get(opts, :encode, fn _bytes, _o -> {:ok, "webp-data"} end),
      store:
        Keyword.get(opts, :store, fn _data, o ->
          {:ok, %{key: "k#{o[:image_order]}", url: "/u#{o[:image_order]}"}}
        end)
    }
  end

  describe "run/3" do
    test "downloads, encodes and stores all images; chapter becomes available", %{
      chapter: chapter,
      snapshot: snapshot
    } do
      assert {:ok, :available} = ChapterDownload.run(chapter.id, snapshot, deps())

      reloaded = Catalog.get_chapter(chapter.id)
      assert reloaded.status == "available"
      assert reloaded.locked_at == nil

      images = Repo.all(from_images(chapter.id))
      assert [_img1, _img2] = images
      assert Enum.map(images, & &1.image_order) == [1, 2]
      assert Enum.all?(images, &(&1.storage_key in ["k1", "k2"]))
      assert Enum.all?(images, &(&1.byte_size == byte_size("webp-data")))

      # Series counters recomputed from source of truth.
      series = Catalog.get_series(chapter.series_id)
      assert series.chapter_count == 1
      refute is_nil(series.last_chapter_at)
    end

    test "is idempotent: rerun replaces previous images", %{chapter: chapter, snapshot: snapshot} do
      assert {:ok, :available} = ChapterDownload.run(chapter.id, snapshot, deps())

      # A retry (e.g. after Oban re-delivery) re-claims the errored/pending
      # chapter and must replace — never duplicate — the image rows.
      Catalog.update_chapter(Catalog.get_chapter(chapter.id), %{status: "pending"})
      assert {:ok, :available} = ChapterDownload.run(chapter.id, snapshot, deps())

      images = Repo.all(from_images(chapter.id))
      assert [_img1, _img2] = images
    end

    test "success resets retry_count after a prior failure (P7-8)", %{
      chapter: chapter,
      snapshot: snapshot
    } do
      failing = Map.put(deps(), :encode, fn _bytes, _o -> {:error, :unsupported} end)
      assert {:error, {:download_failed, _}} = ChapterDownload.run(chapter.id, snapshot, failing)
      assert Catalog.get_chapter(chapter.id).retry_count == 1

      assert {:ok, :available} = ChapterDownload.run(chapter.id, snapshot, deps())
      reloaded = Catalog.get_chapter(chapter.id)
      assert reloaded.retry_count == 0
      assert is_nil(reloaded.last_error)
    end

    test "reclaims a stale processing lock (crash recovery)", %{
      chapter: chapter,
      snapshot: snapshot
    } do
      # Simulate a crashed worker: stuck in processing with an old lock.
      past = DateTime.add(DateTime.utc_now(), -30 * 60)
      Catalog.update_chapter(chapter, %{status: "processing", locked_at: past})

      assert {:ok, :available} = ChapterDownload.run(chapter.id, snapshot, deps())
      assert Catalog.get_chapter(chapter.id).status == "available"
    end

    test "does not reclaim a fresh processing lock", %{chapter: chapter, snapshot: snapshot} do
      Catalog.update_chapter(chapter, %{status: "processing", locked_at: DateTime.utc_now()})

      assert {:error, :not_claimable} = ChapterDownload.run(chapter.id, snapshot, deps())
    end

    test "marks no_images_found when the page has no usable images", %{
      chapter: chapter,
      snapshot: snapshot
    } do
      deps =
        Map.put(deps(), :fetch_html, fn _url, _o ->
          {:ok, "<html><body><div id=\"reader\"></div></body></html>"}
        end)

      assert {:ok, :no_images_found} = ChapterDownload.run(chapter.id, snapshot, deps)

      assert Catalog.get_chapter(chapter.id).status == "no_images_found"
    end

    test "marks error when the encoder fails", %{chapter: chapter, snapshot: snapshot} do
      deps = Map.put(deps(), :encode, fn _bytes, _o -> {:error, :unsupported} end)

      assert {:error, {:download_failed, _}} = ChapterDownload.run(chapter.id, snapshot, deps)

      failed = Catalog.get_chapter(chapter.id)
      assert failed.status == "error"
      assert failed.last_error =~ "images failed"
      assert failed.locked_at == nil
      assert failed.retry_count == 1
    end

    test "marks error when the page fetch fails", %{chapter: chapter, snapshot: snapshot} do
      deps = Map.put(deps(), :fetch_html, fn _url, _o -> {:error, :timeout} end)

      assert {:error, {:download_failed, _}} = ChapterDownload.run(chapter.id, snapshot, deps)

      assert Catalog.get_chapter(chapter.id).status == "error"
    end

    test "partial upload failures mark the chapter for retry", %{
      chapter: chapter,
      snapshot: snapshot
    } do
      deps =
        deps(
          store: fn _data, o ->
            if o[:image_order] == 2,
              do: {:error, :upload_failed},
              else: {:ok, %{key: "k1", url: "/u1"}}
          end
        )

      assert {:error, {:download_failed, _}} = ChapterDownload.run(chapter.id, snapshot, deps)

      assert Catalog.get_chapter(chapter.id).status == "error"
      # No partial rows persisted.
      assert Repo.all(from_images(chapter.id)) == []
    end

    test "refuses to claim a live chapter on the normal download path", %{
      chapter: chapter,
      snapshot: snapshot
    } do
      Catalog.update_chapter(chapter, %{status: "available"})

      assert {:error, :not_claimable} = ChapterDownload.run(chapter.id, snapshot, deps())
    end

    test "force?: true claims an available chapter and replaces its images (repair)", %{
      chapter: chapter,
      snapshot: snapshot
    } do
      assert {:ok, :available} = ChapterDownload.run(chapter.id, snapshot, deps())

      # Admin repair of a published (available) chapter.
      deps = Map.put(deps(), :force?, true)

      assert {:ok, :available} = ChapterDownload.run(chapter.id, snapshot, deps)

      images = Repo.all(from_images(chapter.id))
      assert [_img1, _img2] = images
      assert Catalog.get_chapter(chapter.id).status == "available"
    end

    test "force?: true rescues a no_images_found chapter when the page now has images", %{
      chapter: chapter,
      snapshot: snapshot
    } do
      Catalog.update_chapter(chapter, %{status: "no_images_found"})

      assert {:ok, :available} =
               ChapterDownload.run(chapter.id, snapshot, Map.put(deps(), :force?, true))

      assert Catalog.get_chapter(chapter.id).status == "available"
    end
  end

  defp from_images(chapter_id) do
    import Ecto.Query

    from(i in Crysa.Catalog.ChapterImage,
      where: i.chapter_id == ^chapter_id,
      order_by: i.image_order
    )
  end
end
