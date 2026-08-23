defmodule Crysa.Scraping.TestScrapeTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Crysa.Scraping.{Config, TestScrape}

  @sample_html """
  <html><head><title>Sample</title></head><body>
    <h1 class="series-title">Solo Leveling</h1>
    <img class="series-cover" src="/covers/solo.webp"/>
    <p class="description">A hunter rises again.</p>
    <div class="chapter-list">
      <a href="/ch-12">Chapter 12</a>
      <a href="/ch-11">Chapter 11</a>
    </div>
    <div id="reader">
      <img data-src="https://cdn.example.test/p1.webp"/>
      <img src="https://cdn.example.test/p2.webp"/>
    </div>
  </body></html>
  """

  defp config(attrs) do
    {:ok, config} =
      Config.build(
        Map.merge(
          %{
            "selectors" => %{
              "chapter_link" => ".chapter-list a",
              "image_on_chapter_page" => "#reader img"
            }
          },
          attrs
        )
      )

    config
  end

  test "reports ok for selectors that extract data" do
    cfg =
      config(%{
        "selectors" => %{
          "chapter_link" => ".chapter-list a",
          "image_on_chapter_page" => "#reader img",
          "title" => "h1.series-title",
          "cover" => "img.series-cover",
          "description" => "p.description"
        }
      })

    assert {:ok, report} = TestScrape.run(cfg, @sample_html)

    assert report.valid?
    assert report.chapter_count == 2
    assert report.image_count == 2

    by_field = Map.new(report.checks, &{&1.field, &1})
    assert by_field.chapter_link.status == :ok
    assert by_field.image_on_chapter_page.status == :ok
    assert by_field.title.status == :ok
    assert by_field.title.detail =~ "Solo Leveling"
    assert by_field.cover.status == :ok
    assert by_field.cover.detail =~ "/covers/solo.webp"
    assert by_field.description.status == :ok
  end

  test "skips unconfigured optional selectors" do
    assert {:ok, report} = TestScrape.run(config(%{}), @sample_html)

    assert report.valid?
    skipped = Enum.filter(report.checks, &(&1.status == :skipped))
    assert Enum.map(skipped, & &1.field) == [:title, :cover, :description]
  end

  test "marks empty when a required selector matches nothing" do
    cfg =
      config(%{
        "selectors" => %{
          "chapter_link" => ".does-not-exist",
          "image_on_chapter_page" => "#reader img"
        }
      })

    assert {:ok, report} = TestScrape.run(cfg, @sample_html)
    refute report.valid?

    chapter_check = Enum.find(report.checks, &(&1.field == :chapter_link))
    assert chapter_check.status == :empty
  end

  test "marks empty when a configured metadata selector matches nothing" do
    cfg =
      config(%{
        "selectors" => %{
          "chapter_link" => ".chapter-list a",
          "image_on_chapter_page" => "#reader img",
          "title" => "h1.not-there"
        }
      })

    assert {:ok, report} = TestScrape.run(cfg, @sample_html)
    refute report.valid?
  end

  test "catches silently-truncated selectors (Floki ignores unknown tokens)" do
    # "div >> bad[[[" parses as "div" — parseability checks pass it, but the
    # test scrape proves it extracts nothing useful from the sample.
    cfg =
      config(%{
        "selectors" => %{
          "chapter_link" => ".chapter-list >> bad[[[",
          "image_on_chapter_page" => "#reader img"
        }
      })

    assert {:ok, report} = TestScrape.run(cfg, @sample_html)
    refute report.valid?
  end

  test "binary garbage parses to an invalid (empty) report" do
    # Floki tolerates binary junk and produces an empty document; the report
    # must then fail validation because nothing is extracted.
    assert {:ok, report} = TestScrape.run(config(%{}), <<0, 1, 2>>)
    refute report.valid?
    assert report.chapter_count == 0
  end
end
