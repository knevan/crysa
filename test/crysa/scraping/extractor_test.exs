defmodule Crysa.Scraping.ExtractorTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Crysa.Scraping.Extractor

  describe "extract_chapter/2 — tiered strategies" do
    test "tier 1: pure number text" do
      candidate = Extractor.extract_chapter("https://x.test/r/1", "1")
      assert %{chapter_key: "1", chapter_number: %Decimal{} = num} = candidate
      assert Decimal.eq?(num, 1)

      candidate = Extractor.extract_chapter("https://x.test/r/2", "1,5")
      assert candidate.chapter_key == "1.5"
    end

    test "tier 3: explicit keyword in URL wins over loose" do
      candidate = Extractor.extract_chapter("https://x.test/chapter-105", "")
      assert candidate.chapter_key == "105"
    end

    test "explicit keyword in text is used when URL has none" do
      candidate = Extractor.extract_chapter("https://x.test/read/abc", "Chapter 12")
      assert candidate.chapter_key == "12"
    end

    test "dash-separated numeric parts become decimal identity" do
      candidate = Extractor.extract_chapter("https://x.test/ch-10-5", nil)
      assert candidate.chapter_key == "10.5"
      assert candidate.display_number == "10.5"
      assert Decimal.eq?(candidate.chapter_number, Decimal.new("10.5"))
      assert candidate.sort_key == "000010.005."
    end

    test "whole chapters have clean keys and sort keys" do
      candidate = Extractor.extract_chapter("https://x.test/chapter-105", "Chapter 105")
      assert candidate.chapter_key == "105"
      assert candidate.sort_key == "000105.000."
      assert Decimal.eq?(candidate.chapter_number, Decimal.new("105"))
    end

    test "tier 4 (loose): trailing URL number with year filter" do
      candidate = Extractor.extract_chapter("https://x.test/manga/bleach-120/", nil)
      assert candidate.chapter_key == "120"

      # Whole-number years are rejected by the loose strategy.
      assert Extractor.extract_chapter("https://x.test/manga/bleach-2018/", nil) == nil
    end

    test "loose tier accepts fractional years-like values" do
      candidate = Extractor.extract_chapter("https://x.test/manga/x-2018-5", nil)
      assert candidate.chapter_key == "2018.5"
    end

    test "text starting with a number (loose)" do
      candidate = Extractor.extract_chapter("https://x.test/read/xyz", "123 - Title")
      assert candidate.chapter_key == "123"
    end

    test "suffix chapters keep source-aware keys" do
      candidate = Extractor.extract_chapter("https://x.test/ch-10-extra", "Ch 10 extra")
      assert candidate.chapter_key == "10-extra"
      assert candidate.display_number == "10-extra"
      assert is_nil(candidate.chapter_number)
      assert candidate.sort_key == "000010.000.extra"
    end

    test "keywords embedded in words do not match explicitly" do
      # "bleach" contains "ch"; the lookbehind prevents an explicit match and
      # the year filter rejects the loose match.
      assert Extractor.extract_chapter("https://x.test/manga/bleach-2018/", nil) == nil
    end

    test "values above the maximum chapter are rejected" do
      assert Extractor.extract_chapter("https://x.test/chapter-99999", nil) == nil
    end

    test "fractional parts beyond DB scale fall through" do
      assert Extractor.extract_chapter("https://x.test/ch-10.9999", "x") == nil
    end

    test "no match returns nil" do
      assert Extractor.extract_chapter("https://x.test/nothing-here", "") == nil
    end
  end

  describe "extract_image_url/1" do
    test "prefers lazy-load attributes over src" do
      el = element(~s(<img src="a.jpg" data-src="b.webp">))
      assert Extractor.extract_image_url(el) == "b.webp"
    end

    test "srcset resolves to the last (highest resolution) entry" do
      el = element(~s(<img srcset="small.jpg 480w, large.jpg 1080w">))
      assert Extractor.extract_image_url(el) == "large.jpg"
    end

    test "rejects tracking pixels by dimension" do
      el = element(~s(<img src="pixel.gif" width="1" height="1">))
      assert Extractor.extract_image_url(el) == nil
    end

    test "rejects data URIs, junk keywords and bad extensions" do
      assert Extractor.extract_image_url(element(~s(<img src="data:image/png;base64,AAA">))) ==
               nil

      assert Extractor.extract_image_url(element(~s(<img src="placeholder.png">))) == nil
      assert Extractor.extract_image_url(element(~s(<img src="logo.svg">))) == nil
      assert Extractor.extract_image_url(element(~s[<img src="javascript:void(0)">])) == nil
    end

    defp element(html) do
      {:ok, doc} = Floki.parse_document(html)
      hd(Floki.find(doc, "img"))
    end
  end
end
