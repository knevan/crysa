defmodule Crysa.Scraping.Extractor do
  @moduledoc """
  Smart extraction of chapter identities and image URLs from link text,
  URLs and HTML elements.

  Direct port of Castra's `SmartChapterExtractor` / `SmartImageExtractor`
  (`scraping/extractor.rs`), adapted to the non-float chapter identity model:

    * Tier 1 — link text is a pure number ("1", "1.5"): strict validation.
    * Tier 2 — explicit keyword plus numeric major and an alphabetic suffix
      in the URL ("ch-10-extra"), which has no float equivalent.
    * Tier 3 — explicit keyword in URL then text ("chapter-105", "Ch.1.5",
      "ep-5"): strict validation.
    * Tier 4 — loose heuristics: trailing number in the URL ("/manga/x-120")
      or text starting with a number ("123 - Title"), with a year-range
      filter to avoid treating "bleach-2018" as a chapter.

  Fractional parts with more than three digits are rejected because they do
  not fit the `numeric(12,3)` helper column; the candidate falls through to
  lower-confidence tiers instead of being silently truncated.
  """

  alias Crysa.Scraping.ChapterCandidate

  @max_valid_chapter 10_000
  @min_year_filter 1990
  @max_year_filter 2100
  @max_fraction_digits 3

  # Matches: "Chapter 1", "ch 1", "Ch.1.5", "Ep 5", "Vol. 1", "No. 10"
  # \b prevents matching keywords embedded in other words.
  @explicit_text_regex ~r/\b(?:chapter|ch|chap|episode|ep|vol|no)[\s.\-_]*(\d+(?:[.,\-]\d+)?)/i

  # Match strings starting with a number: "123 - Title" (but not "123Title")
  @text_start_number_regex ~r/^(\d+(?:[.,\-]\d+)?)\b/

  # Matches URL explicit: "chapter-123", "ch-10-5". The negative lookbehind
  # keeps "bleach-2018" from matching the "ch" inside "bleach".
  @url_explicit_regex ~r/(?<![a-z0-9])(?:chapter|ch|chap|episode|ep|vol|no)[^a-z0-9]+(\d+(?:[.\-]\d+)?)/i

  # Matches URL loose end: "/123", "/123/", "/123?v=1"
  @url_loose_regex ~r/[^a-z0-9](\d+(?:[.\-]\d+)?)(?:\/?$|[?#])/i

  # Matches explicit keyword + major number + alpha suffix:
  # "ch-10-extra", "chapter-12-special" → {:suffix, major, suffix}
  @url_suffix_regex ~r/(?<![a-z0-9])(?:chapter|ch|chap|episode|ep|vol|no)[^a-z0-9]+(\d{1,6})[.\-]([a-z][a-z0-9]{0,15})(?:\/?$|[?#\/])/i

  @typedoc "Numeric components `{major, minor}` as digit strings."
  @type numeric_parts :: {String.t(), String.t()}

  @typedoc """
  Matched parts: numeric `{major, minor}` or suffixed `{:suffix, major, suffix}`.
  """
  @type matched_parts :: numeric_parts() | {:suffix, String.t(), String.t()}

  @doc """
  Extracts chapter identity from an absolute URL and its link text.

  Returns `%ChapterCandidate{}` or `nil` when no tier matches.
  """
  @spec extract_chapter(String.t(), String.t() | nil) :: ChapterCandidate.t() | nil
  def extract_chapter(url, text) when is_binary(url) do
    text = String.trim(text || "")

    case match_tiers(url, text) do
      nil -> nil
      parts -> build_candidate(url, text, parts)
    end
  end

  defp match_tiers(url, text) do
    tier1(text) || tier_suffix(url) || tier2(url, text) || tier3(url, text)
  end

  # -- Tier 1: pure number text ----------------------------------------------

  defp tier1(text) do
    if Regex.match?(~r/\A\d+(?:[.,]\d+)?\z/, text) do
      text |> String.replace(",", ".") |> split_number() |> validate_strict()
    end
  end

  # -- Tier 2: explicit keyword + alpha suffix ---------------------------------

  defp tier_suffix(url) do
    case Regex.run(@url_suffix_regex, url) do
      [_, major, suffix] -> {:suffix, major, String.downcase(suffix)}
      _ -> nil
    end
  end

  # -- Tier 3: explicit keyword numeric (URL first, then text) ----------------

  defp tier2(url, text) do
    url |> last_capture(@url_explicit_regex) |> validate_strict() ||
      text |> last_capture(@explicit_text_regex) |> validate_strict()
  end

  # -- Tier 4: loose heuristics with year filter ------------------------------

  defp tier3(url, text) do
    url |> last_capture(@url_loose_regex) |> validate_loose() ||
      text |> text_start_number() |> validate_loose()
  end

  defp text_start_number(text) do
    case Regex.run(@text_start_number_regex, text) do
      [_, raw] -> split_number(raw)
      _ -> nil
    end
  end

  # -- Validation --------------------------------------------------------------

  defp validate_strict(nil), do: nil

  defp validate_strict({major, minor}) do
    if valid_range?(major) and valid_fraction?(minor), do: {major, minor}
  end

  defp validate_loose(nil), do: nil

  defp validate_loose({major, minor}) do
    if valid_range?(major) and valid_fraction?(minor) and not year_like?(major, minor) do
      {major, minor}
    end
  end

  defp valid_range?(major) do
    case Integer.parse(major) do
      {value, ""} -> value >= 0 and value <= @max_valid_chapter
      _ -> false
    end
  end

  defp valid_fraction?(minor), do: String.length(minor) <= @max_fraction_digits

  defp year_like?(major, "000") do
    case Integer.parse(major) do
      {value, ""} -> value >= @min_year_filter and value <= @max_year_filter
      _ -> false
    end
  end

  defp year_like?(_, _), do: false

  # -- Helpers ------------------------------------------------------------------

  defp last_capture(haystack, regex) do
    case Regex.scan(regex, haystack) do
      [] ->
        nil

      matches ->
        [_, raw] = List.last(matches)
        split_number(raw)
    end
  end

  defp split_number(raw) do
    # Castra's parse_clean_number: ',' and '-' separators are decimal points.
    case String.split(String.replace(raw, [",", "-"], "."), ".", parts: 2) do
      [major] -> {major, "000"}
      [major, minor] -> {major, minor}
    end
  end

  defp build_candidate(url, text, {:suffix, major, suffix}) do
    ChapterCandidate.build(url, non_blank(text), {major, suffix})
  end

  defp build_candidate(url, text, parts) do
    ChapterCandidate.build(url, non_blank(text), parts)
  end

  defp non_blank(""), do: nil
  defp non_blank(text), do: text

  # -- Image URL extraction (SmartImageExtractor port) -------------------------

  @img_attr_priority [
    "data-src",
    "data-lazy-src",
    "data-original",
    "data-url",
    "data-srcset",
    "srcset",
    "src"
  ]

  @junk_keywords [
    "data:image/",
    "placeholder",
    "pixel",
    "loader",
    "loading",
    "transparent",
    "blank",
    "avatar",
    "icon",
    "google-analytics",
    "histats"
  ]

  @bad_extensions ~w(svg ico js css html)

  @doc """
  Extracts the best image URL candidate from an HTML element.

  Attributes are probed in priority order (lazy-load attributes before
  `src`); `srcset` values resolve to the last (highest resolution) entry.
  Tracking pixels (width/height <= 2), data URIs, junk keywords and bad
  extensions are rejected. Returns the raw attribute value — absolutization
  is the parser's job.
  """
  @spec extract_image_url(term()) :: String.t() | nil
  def extract_image_url(element) do
    if tracking_pixel?(element) do
      nil
    else
      Enum.find_value(@img_attr_priority, fn attr -> image_from_attr(element, attr) end)
    end
  end

  defp image_from_attr(element, attr) do
    case Floki.attribute(element, attr) do
      [value | _] -> value |> String.trim() |> validate_attr_value(attr)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp validate_attr_value("", _attr), do: nil

  defp validate_attr_value(value, attr) when attr in ["data-srcset", "srcset"] do
    src = parse_srcset(value)
    if src && valid_url_candidate?(src), do: src
  end

  defp validate_attr_value(value, _attr) do
    if valid_url_candidate?(value), do: value
  end

  defp valid_url_candidate?(url) do
    lower = String.downcase(url)

    not dangerous_protocol?(lower) and not junk?(lower) and not bad_extension?(lower)
  end

  defp dangerous_protocol?(lower) do
    String.starts_with?(lower, "javascript") or String.starts_with?(lower, "mailto:")
  end

  defp junk?(lower), do: Enum.any?(@junk_keywords, &String.contains?(lower, &1))

  defp bad_extension?(lower) do
    ext =
      lower
      |> String.split(".")
      |> List.last()
      |> String.split(["?", "#"])
      |> List.first()

    ext in @bad_extensions
  end

  defp tracking_pixel?(element) do
    small_dimension?(attr_int(element, "width")) or small_dimension?(attr_int(element, "height"))
  end

  defp attr_int(element, attr) do
    case Floki.attribute(element, attr) do
      [value | _] -> leading_int(value)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp leading_int(value) do
    digits = String.slice(value, 0, leading_digit_span(value))

    case Integer.parse(digits) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp leading_digit_span(value) do
    value
    |> String.to_charlist()
    |> Enum.take_while(&(&1 in ?0..?9))
    |> length()
  end

  defp small_dimension?(dimension) when is_integer(dimension), do: dimension <= 2
  defp small_dimension?(_), do: false

  # Takes the LAST entry of a srcset (highest resolution candidate).
  defp parse_srcset(srcset) do
    srcset
    |> String.split(",")
    |> List.last()
    |> String.trim()
    |> String.split(" ", parts: 2)
    |> List.first()
    |> case do
      "" -> nil
      url -> url
    end
  end
end
