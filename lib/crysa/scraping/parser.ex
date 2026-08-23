defmodule Crysa.Scraping.Parser do
  @moduledoc """
  HTML parsing for chapter links and chapter images using Floki.

  Port of Castra's `ChapterParser` (`scraping/parser.rs`). Unlike Rust's
  `scraper` crate, Floki has no compiled-selector cache, so selectors are
  re-parsed per call — their correctness is guaranteed by config validation
  and the publish-time test scrape, not here.

  All functions are pure: HTML in, data out. Network access belongs to
  `Crysa.Scraping.Fetcher` and orchestration to `Crysa.Processing`.
  """

  alias Crysa.Scraping.ChapterCandidate
  alias Crysa.Scraping.Config
  alias Crysa.Scraping.Extractor

  @typedoc "Parsed HTML document as returned by `Floki.parse_document/1`."
  @type document :: Floki.html_tree() | Floki.html_document()

  @doc "Parses an HTML string into a Floki document."
  @spec parse_document(String.t()) :: {:ok, document()} | {:error, term()}
  def parse_document(html) when is_binary(html), do: Floki.parse_document(html)

  @doc """
  Quick check: extracts only the latest chapter from a series page,
  honouring the configured `chapter_order` (`desc` → first match, `asc` →
  last match).
  """
  @spec quick_check_latest(document(), String.t(), Config.t()) :: ChapterCandidate.t() | nil
  def quick_check_latest(document, base_url, %Config{} = config) do
    selector = config.selectors.chapter_link

    elements = Floki.find(document, selector)

    element =
      if config.chapter_order == "asc" do
        List.last(elements)
      else
        List.first(elements)
      end

    candidate_from_element(element, base_url)
  end

  @doc """
  Full scan: extracts all chapters, deduplicated by `chapter_key`
  (first occurrence wins, mirroring Castra's `entry().or_insert`) and sorted
  ascending by `sort_key`.
  """
  @spec full_scan_chapters(document(), String.t(), Config.t()) :: [ChapterCandidate.t()]
  def full_scan_chapters(document, base_url, %Config{} = config) do
    document
    |> Floki.find(config.selectors.chapter_link)
    |> Enum.flat_map(&(candidate_from_element(&1, base_url) |> List.wrap()))
    |> dedupe_by_key()
    |> Enum.sort_by(& &1.sort_key)
  end

  @doc """
  Extracts image URLs from a chapter page in document order, deduplicated.
  Relative URLs are resolved against the chapter URL.
  """
  @spec extract_image_urls(document(), String.t(), Config.t()) :: [String.t()]
  def extract_image_urls(document, base_url, %Config{} = config) do
    document
    |> Floki.find(config.selectors.image_on_chapter_page)
    |> Enum.map(&Extractor.extract_image_url/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&absolute_url(base_url, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  # -- internals ----------------------------------------------------------------

  defp candidate_from_element(nil, _base_url), do: nil

  defp candidate_from_element(element, base_url) do
    with {:ok, href} <- fetch_href(element),
         trimmed = String.trim(href),
         false <- trimmed == "",
         %URI{scheme: scheme, host: host} = absolute
         when scheme in ["http", "https"] and is_binary(host) <-
           absolute_uri(base_url, trimmed) do
      text = element_text(element)
      Extractor.extract_chapter(URI.to_string(absolute), text)
    else
      _ -> nil
    end
  end

  defp fetch_href(element) do
    case Floki.attribute(element, "href") |> List.first() do
      nil -> {:error, :no_href}
      href -> {:ok, href}
    end
  rescue
    _ -> {:error, :attribute_failure}
  end

  defp dedupe_by_key(candidates) do
    candidates
    |> Enum.reduce({%{}, []}, fn candidate, {seen, acc} ->
      if Map.has_key?(seen, candidate.chapter_key) do
        {seen, acc}
      else
        {Map.put(seen, candidate.chapter_key, true), [candidate | acc]}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp element_text(element) do
    element |> Floki.text() |> String.trim()
  rescue
    _ -> ""
  end

  defp absolute_uri(base_url, href) do
    case URI.new(base_url) do
      {:ok, base} -> URI.merge(base, href)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp absolute_url(base_url, raw_url) do
    case absolute_uri(base_url, raw_url) do
      %URI{scheme: scheme, host: host} = uri
      when scheme in ["http", "https"] and is_binary(host) ->
        URI.to_string(uri)

      _ ->
        nil
    end
  end
end
