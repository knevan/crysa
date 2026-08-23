defmodule Crysa.Scraping.TestScrape do
  @moduledoc """
  Publish-time test scrape: runs a candidate config document against sample
  HTML and reports what every configured selector actually extracts.

  Pure function — no network access, no database writes. The admin UI
  (Phase 8) invokes this before `Crysa.Scraping.publish_version/3` and may
  persist the returned report in `scraping_site_test_runs`.

  Why this exists: Floki silently ignores unknown CSS selector tokens (e.g.
  `"a >> ["` parses as `"a"`), so parseability alone cannot prove a selector
  is semantically correct. Only executing it against representative HTML
  does — this module is that execution.
  """

  alias Crysa.Scraping.Config
  alias Crysa.Scraping.Parser

  @typedoc "Outcome of one selector check."
  @type check :: %{
          required(:field) => atom(),
          required(:status) => :ok | :empty | :skipped,
          required(:detail) => String.t() | nil
        }

  @type report :: %{
          required(:checks) => [check()],
          required(:chapter_count) => non_neg_integer(),
          required(:image_count) => non_neg_integer(),
          required(:valid?) => boolean()
        }

  @metadata_fields [:title, :cover, :description]

  @doc """
  Runs all selector checks for `config` against `html`.

  Options:

    * `:base_url` — base for resolving relative URLs (default test host).

  The report is `valid?: true` when the two required selectors
  (`chapter_link`, `image_on_chapter_page`) each extract at least one result
  and every *configured* optional metadata selector is non-empty.
  """
  @spec run(Config.t(), String.t(), keyword()) :: {:ok, report()} | {:error, term()}
  def run(%Config{} = config, html, opts \\ []) when is_binary(html) do
    base_url = Keyword.get(opts, :base_url, "https://test-scrape.example/")

    with {:ok, doc} <- Parser.parse_document(html) do
      chapters = Parser.full_scan_chapters(doc, base_url, config)
      images = Parser.extract_image_urls(doc, base_url, config)

      checks =
        [
          check_chapters(chapters),
          check_images(images)
        ] ++ Enum.map(@metadata_fields, &check_metadata(doc, config, &1))

      valid? = Enum.all?(checks, &(&1.status in [:ok, :skipped]))

      {:ok,
       %{
         checks: checks,
         chapter_count: length(chapters),
         image_count: length(images),
         valid?: valid?
       }}
    end
  end

  # -- checks -------------------------------------------------------------------

  defp check_chapters(chapters) do
    case chapters do
      [] ->
        %{field: :chapter_link, status: :empty, detail: "no chapter links extracted"}

      list ->
        keys = list |> Enum.take(3) |> Enum.map(& &1.chapter_key)

        %{
          field: :chapter_link,
          status: :ok,
          detail: "#{length(list)} chapters, e.g. #{Enum.join(keys, ", ")}"
        }
    end
  end

  defp check_images(images) do
    case images do
      [] ->
        %{field: :image_on_chapter_page, status: :empty, detail: "no image URLs extracted"}

      list ->
        %{field: :image_on_chapter_page, status: :ok, detail: "#{length(list)} images found"}
    end
  end

  defp check_metadata(doc, config, field) do
    selector = Map.get(config.selectors, field)

    if is_binary(selector) do
      check_configured_selector(doc, field, selector)
    else
      %{field: field, status: :skipped, detail: nil}
    end
  end

  defp check_configured_selector(doc, field, selector) do
    case Floki.find(doc, selector) do
      [] ->
        %{field: field, status: :empty, detail: "selector matched nothing"}

      [element | _] ->
        check_extracted_value(field, element)
    end
  end

  defp check_extracted_value(field, element) do
    value = extracted_value(field, element)

    if value in [nil, ""] do
      %{field: field, status: :empty, detail: "matched element but extracted no value"}
    else
      %{field: field, status: :ok, detail: "extracted \"" <> String.slice(value, 0, 80) <> "\""}
    end
  end

  defp extracted_value(:cover, element), do: Crysa.Scraping.Extractor.extract_image_url(element)

  defp extracted_value(_field, element), do: element |> Floki.text() |> String.trim()
end
