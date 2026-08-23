defmodule Crysa.Scraping.ParserTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Crysa.Scraping.{Config, Parser}

  @base "https://manga.example.test/series/abc"

  defp config(chapter_order \\ "desc") do
    {:ok, config} =
      Config.build(%{
        "selectors" => %{
          "chapter_link" => ".chapter-list a",
          "image_on_chapter_page" => "#reader img"
        },
        "chapter_order" => chapter_order
      })

    config
  end

  defp chapter_doc do
    """
    <html><body>
      <div class="chapter-list">
        <a href="/ch-105">Chapter 105</a>
        <a href="">empty</a>
        <a href="javascript:void(0)">bad</a>
        <a href="https://other.test/ch-104">Chapter 104</a>
        <a href="ch-10-5">Chapter 10.5</a>
      </div>
    </body></html>
    """
  end

  describe "quick_check_latest/3" do
    test "returns the first match for desc order" do
      {:ok, doc} = Parser.parse_document(chapter_doc())
      candidate = Parser.quick_check_latest(doc, @base, config("desc"))
      assert candidate.chapter_key == "105"
    end

    test "returns the last match for asc order" do
      {:ok, doc} = Parser.parse_document(chapter_doc())
      candidate = Parser.quick_check_latest(doc, @base, config("asc"))
      assert candidate.chapter_key == "10.5"
    end

    test "returns nil when nothing matches" do
      {:ok, doc} = Parser.parse_document("<html><body></body></html>")
      assert Parser.quick_check_latest(doc, @base, config()) == nil
    end
  end

  describe "full_scan_chapters/3" do
    test "dedupes by chapter key and sorts by sort key" do
      html = """
      <html><body><div class="chapter-list">
        <a href="/ch-105">Chapter 105</a>
        <a href="/ch-105">Chapter 105 (dup)</a>
        <a href="/ch-10-5">Chapter 10.5</a>
        <a href="/ch-1">Chapter 1</a>
      </div></body></html>
      """

      {:ok, doc} = Parser.parse_document(html)
      candidates = Parser.full_scan_chapters(doc, @base, config())

      keys = Enum.map(candidates, & &1.chapter_key)
      assert keys == ["1", "10.5", "105"]
    end

    test "resolves relative URLs against the base" do
      {:ok, doc} = Parser.parse_document(chapter_doc())

      [first | _] = Parser.full_scan_chapters(doc, @base, config())
      # sorted ascending: first is the lowest chapter; find the absolute one instead
      assert Enum.any?(Parser.full_scan_chapters(doc, @base, config()), fn c ->
               c.url == "https://other.test/ch-104"
             end)

      assert String.starts_with?(first.url, "https://manga.example.test/")
    end
  end

  describe "extract_image_urls/3" do
    test "extracts in document order, absolutized and deduped" do
      html = """
      <html><body><div id="reader">
        <img data-src="https://cdn.example.test/p1.webp"/>
        <img src="/img/p2.jpg"/>
        <img src="//static.example.test/p3.png"/>
        <img src="https://cdn.example.test/p1.webp"/>
        <img src="pixel.gif" width="1" height="1"/>
      </div></body></html>
      """

      {:ok, doc} = Parser.parse_document(html)
      urls = Parser.extract_image_urls(doc, "https://manga.example.test/ch/105", config())

      assert urls == [
               "https://cdn.example.test/p1.webp",
               "https://manga.example.test/img/p2.jpg",
               "https://static.example.test/p3.png"
             ]
    end
  end
end
