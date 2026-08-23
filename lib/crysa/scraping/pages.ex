defmodule Crysa.Scraping.Pages do
  @moduledoc """
  Chapter-list page URL enumeration driven by the site's pagination config.

  Three configured forms (see `Crysa.Scraping.Config.Pagination`):

    * `none` — yields only the series page itself.
    * `query_param` — the series page counts as page `start`; yields
      `series_url?param=N` for `N = start+1 .. start+max_pages-1`.
    * `ajax` — same page numbering, but each additional page is fetched from
      `url_template` with `{page}` replaced by the page number.

  Every form is bounded: `page_urls/2` returns at most `max_pages` URLs
  **including** the series page, so total outbound requests are capped by
  `max_pages` regardless of pagination type. Runtime consumers must
  additionally stop on empty pages and on pages that produce no new chapter
  keys — see `Crysa.Processing.SeriesCheck` which enforces those dynamic
  stop conditions while consuming this list.
  """

  alias Crysa.Scraping.Config

  @doc """
  Returns the list of page URLs to fetch for a full scan, in fetch order.

  The series page is always first; pagination URLs follow it.
  """
  @spec page_urls(String.t(), Config.t()) :: [String.t()]
  def page_urls(series_url, %Config{} = config) do
    case config.pagination do
      %{type: "none"} ->
        [series_url]

      %{type: "query_param", param: param, start: start, max_pages: max_pages} ->
        [series_url | query_param_urls(series_url, param, start || 1, max_pages || 1)]

      %{type: "ajax", url_template: template, start: start, max_pages: max_pages} ->
        [series_url | ajax_urls(template, start || 1, max_pages || 1)]
    end
  end

  # Both iteration forms yield exactly `max_pages - 1` additional URLs after
  # the series page (which itself counts as page `start`), so the total fetch
  # count is bounded by `max_pages` regardless of pagination type.
  defp query_param_urls(series_url, param, start, max_pages) do
    pages_after_first = max_pages - 1

    if pages_after_first <= 0 do
      []
    else
      Enum.map((start + 1)..(start + pages_after_first)//1, fn page ->
        add_query_param(series_url, param, page)
      end)
    end
  end

  defp ajax_urls(template, start, max_pages) do
    pages_after_first = max_pages - 1

    if pages_after_first <= 0 do
      []
    else
      Enum.map((start + 1)..(start + pages_after_first)//1, fn page ->
        String.replace(template, "{page}", Integer.to_string(page))
      end)
    end
  end

  defp add_query_param(url, param, value) do
    case URI.new(url) do
      {:ok, uri} ->
        uri
        |> merge_param(param, Integer.to_string(value))
        |> URI.to_string()

      _ ->
        url
    end
  end

  defp merge_param(%URI{} = uri, param, value) do
    existing =
      if is_binary(uri.query) and uri.query != "" do
        URI.decode_query(uri.query)
      else
        %{}
      end

    %URI{uri | query: URI.encode_query(Map.put(existing, param, value))}
  end
end
