defmodule Crysa.Processing.SeriesCheck do
  @moduledoc """
  Series check engine: quick check, count check and paginated full scan.

  Port of Castra's `processing/orchestrator.rs::run_series_check`, adapted
  to CrysA's config snapshots, canonical chapter keys and durable jobs:

    1. Fetch the series page through the per-host throttled fetcher.
    2. **Quick check** — parse only the latest chapter; if its `sort_key`
       exceeds the highest known key in the database, a full scan is needed.
    3. **Count check** — otherwise compare the on-page chapter count with
       the database count; a mismatch also triggers a full scan.
    4. **Full scan** — iterate the configured pagination pages with bounded
       stop conditions (`max_pages`, empty pages, pages that add no new
       keys), dedupe by `chapter_key`.
    5. Upsert all scanned chapters idempotently; enqueue a download job for
       every newly inserted row plus any chapter still pending/errored.

  HTTP access is injected via `:fetch_html` (defaulting to
  `Crysa.Scraping.Fetcher.fetch_html/2` including throttling) so tests run
  against fixture HTML without network access.
  """

  import Ecto.Query

  require Logger

  alias Crysa.Catalog.Chapter
  alias Crysa.Processing.Jobs.ChapterDownloadWorker
  alias Crysa.Repo
  alias Crysa.Scraping.{Config, Pages, Parser}

  @type snapshot :: %{config: Config.t(), version: pos_integer()}

  @type result ::
          {:ok, :no_chapters_found}
          | {:ok, :up_to_date}
          | {:ok, {:enqueued, non_neg_integer()}}
          | {:error, term()}

  @max_chapters_per_scan 5_000

  # -- Public API ---------------------------------------------------------------

  @doc """
  Runs a check for `series` using the published config `snapshot`.

  Options:

    * `:fetch_html` — `(url -> {:ok, body} | {:error, reason})`; defaults to
      the real fetcher including throttling.
    * `:enqueue?` — set `false` to skip Oban enqueuing (tests/dry runs).
  """
  @spec run(Crysa.Catalog.Series.t(), snapshot(), keyword()) :: result()
  def run(series, snapshot, opts \\ []) do
    fetch_html = Keyword.get(opts, :fetch_html, &default_fetch(&1, snapshot))
    enqueue? = Keyword.get(opts, :enqueue?, true)
    config = snapshot.config

    with {:ok, html} <- fetch_page(series, fetch_html),
         {:ok, doc} <- parse(html) do
      latest = Parser.quick_check_latest(doc, series.source_url, config)
      max_known_key = max_known_sort_key(series.id)

      cond do
        is_nil(latest) ->
          {:ok, :no_chapters_found}

        needs_full_scan?(latest, max_known_key, doc, series, config) ->
          run_full_scan(doc, series, fetch_html, config, max_known_key, enqueue?)

        true ->
          {:ok, :up_to_date}
      end
    end
  end

  # -- Steps ----------------------------------------------------------------------

  defp fetch_page(series, fetch_html) do
    case fetch_html.(series.source_url) do
      {:ok, html} -> {:ok, html}
      {:error, reason} -> {:error, {:fetch_failed, reason}}
    end
  end

  # Compares *parsed chapter candidates* on the first page against stored
  # rows — not raw selector matches, which include non-chapter elements and
  # would trigger a pointless full scan on every check (review finding P7-6).
  defp needs_full_scan?(latest, max_known_key, doc, series, config) do
    if is_nil(max_known_key) or latest.sort_key > max_known_key do
      true
    else
      site_count =
        doc
        |> Parser.full_scan_chapters(series.source_url, config)
        |> length()

      db_count = known_chapter_count(series.id)
      site_count != db_count
    end
  end

  defp run_full_scan(doc, series, fetch_html, config, _max_known_key, enqueue?) do
    candidates = full_scan(doc, series, fetch_html, config)

    cond do
      candidates == [] ->
        {:ok, :no_chapters_found}

      length(candidates) > @max_chapters_per_scan ->
        {:error, {:too_many_chapters, length(candidates)}}

      true ->
        insert_and_enqueue(series, candidates, enqueue?)
    end
  end

  @doc """
  Full scan across all configured pagination pages.

  Stop conditions (explicit and bounded):

    * `max_pages` from the pagination config (hard-capped at 200 by the
      config schema).
    * A page whose parsed chapter list is empty.
    * A page that contributes no new `chapter_key`s (duplicate/looping page).
    * A later page that fails to fetch or parse (keep what was collected).
  """
  @spec full_scan(
          Floki.html_tree() | Floki.html_document(),
          Crysa.Catalog.Series.t(),
          (String.t() -> term()),
          Config.t()
        ) ::
          [Crysa.Scraping.ChapterCandidate.t()]
  def full_scan(first_doc, series, fetch_html, config) do
    Pages.page_urls(series.source_url, config)
    |> Enum.reduce_while({[], MapSet.new()}, fn url, acc ->
      reduce_page(url, first_doc, series, fetch_html, config, acc)
    end)
    |> elem(0)
    |> Enum.sort_by(& &1.sort_key)
  end

  defp reduce_page(url, first_doc, series, fetch_html, config, acc) do
    case page_candidates(url, first_doc, series, fetch_html, config) do
      {:error, reason} ->
        Logger.warning("series check page failed",
          series_id: series.id,
          host: host_of(url),
          reason: inspect(reason)
        )

        # A broken later page must not abort the whole scan: keep what we have.
        {:halt, acc}

      [] ->
        # Empty page: nothing more to collect.
        {:halt, acc}

      found ->
        merge_found(found, acc)
    end
  end

  defp merge_found(found, {candidates, seen}) do
    fresh = Enum.reject(found, &MapSet.member?(seen, &1.chapter_key))

    if fresh == [] do
      # Duplicate page (pagination loop): stop before burning max_pages.
      {:halt, {candidates, seen}}
    else
      new_seen = MapSet.union(seen, MapSet.new(fresh, & &1.chapter_key))
      {:cont, {candidates ++ fresh, new_seen}}
    end
  end

  defp page_candidates(url, first_doc, series, fetch_html, config) do
    result =
      if url == series.source_url do
        # First page was already fetched/parsed by the caller.
        {:ok, first_doc}
      else
        with {:ok, html} <- fetch_html.(url) do
          Parser.parse_document(html)
        end
      end

    case result do
      {:ok, doc} -> Parser.full_scan_chapters(doc, url, config)
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse(html) do
    case Parser.parse_document(html) do
      {:ok, doc} -> {:ok, doc}
      {:error, reason} -> {:error, {:parse_failed, reason}}
    end
  end

  defp insert_and_enqueue(series, candidates, enqueue?) do
    now = DateTime.utc_now()

    rows =
      Enum.map(Enum.sort_by(candidates, & &1.sort_key), fn c ->
        %{
          series_id: series.id,
          chapter_key: c.chapter_key,
          display_number: c.display_number,
          title: c.title,
          chapter_number: c.chapter_number,
          sort_key: c.sort_key,
          source_url: c.url,
          status: "pending",
          retry_count: 0,
          inserted_at: now,
          updated_at: now
        }
      end)

    {_count, inserted} =
      Repo.insert_all(Chapter, rows,
        on_conflict: :nothing,
        conflict_target: [:series_id, :chapter_key],
        returning: [:id]
      )

    # Chapters above the watermark that were stored earlier but never
    # downloaded still need a job; newly inserted ones always do.
    pending_ids =
      Repo.all(
        from(c in Chapter,
          where: c.series_id == ^series.id and c.status in ["pending", "error"],
          select: c.id
        )
      )

    ids = Enum.uniq(Enum.map(inserted, & &1.id) ++ pending_ids)

    if enqueue? and ids != [] do
      Enum.each(ids, fn chapter_id ->
        %{series_id: series.id, chapter_id: chapter_id}
        |> ChapterDownloadWorker.new()
        |> Oban.insert()
      end)
    end

    {:ok, {:enqueued, length(ids)}}
  end

  # -- DB reads ---------------------------------------------------------------------

  defp max_known_sort_key(series_id) do
    Repo.one(from(c in Chapter, where: c.series_id == ^series_id, select: max(c.sort_key)))
  end

  defp known_chapter_count(series_id) do
    Repo.one(from(c in Chapter, where: c.series_id == ^series_id, select: count())) || 0
  end

  # -- Default dependencies -------------------------------------------------------------

  defp default_fetch(url, snapshot) do
    Crysa.Scraping.Fetcher.fetch_html(url, rate_limit: snapshot.config.rate_limit)
  end

  defp host_of(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) -> host
      _ -> "unknown"
    end
  end
end
