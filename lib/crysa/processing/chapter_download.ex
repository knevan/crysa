defmodule Crysa.Processing.ChapterDownload do
  @moduledoc """
  Chapter download pipeline: fetch page → extract images → download →
  encode WebP → upload to storage → persist image rows.

  Port of Castra's `processing/coordinator.rs::process_single_chapter` with
  the plan's robustness requirements applied:

    * **Idempotent**: a (re)run first deletes any existing image rows and
      their storage objects, so retries after crashes never duplicate data.
    * **No transactions around network/storage calls**: the database is only
      touched before (claim) and after (persist) the external work.
    * **Resource limits**: byte-size caps via the fetcher, encode limits via
      `Crysa.Images.Limits`, bounded concurrency from the Oban queue.
    * **Explicit state machine**: `pending/errored → processing → available |
      no_images_found | error`, with `locked_at` claim semantics.

  External dependencies are injectable (`:fetch_html`, `:fetch_bytes`,
  `:encode`, `:store`) so tests run without network, storage or encoders.
  """

  import Ecto.Query

  require Logger

  alias Crysa.Catalog.Chapter
  alias Crysa.Images.Encoder
  alias Crysa.Images.Limits
  alias Crysa.Repo
  alias Crysa.Scraping.Config
  alias Crysa.Storage

  @type snapshot :: %{config: Config.t(), version: pos_integer()}

  @max_chapter_images 300
  @error_truncate 2_000
  # A chapter stuck in `processing` (crashed worker) becomes reclaimable
  # after this many minutes so Oban retries are never blocked by a stale lock.
  @stale_lock_minutes 15
  # States claimable by the normal download path; repair (`force?: true`)
  # additionally claims live chapters to replace their images.
  @claimable_states ["pending", "error"]

  # -- Public API ---------------------------------------------------------------

  @doc """
  Downloads and stores `chapter_id` using the config `snapshot`.

  Options:

    * `:force?` — when `true` (repair flow), also claims chapters in
      `available`/`no_images_found` state, replacing their images. The normal
      download path keeps the strict pending/error claim.

  Returns:

    * `{:ok, :available}` — all images stored.
    * `{:ok, :no_images_found}` — page parsed but contained no usable images.
    * `{:error, term()}` — chapter left in `error` state for retry.
  """
  @spec run(integer(), snapshot(), keyword()) ::
          {:ok, :available} | {:ok, :no_images_found} | {:error, term()}
  def run(chapter_id, snapshot, opts \\ []) when is_integer(chapter_id) do
    deps = build_deps(opts)

    with {:ok, chapter} <- claim(chapter_id, force?: get_opt(opts, :force?, false)),
         {:ok, series} <- fetch_series(chapter.series_id),
         :ok <- reset_existing_images(chapter.id) do
      process(chapter, series, snapshot, deps)
    end
  end

  # -- Claim / reset -----------------------------------------------------------------

  defp claim(chapter_id, opts) do
    now = DateTime.utc_now()
    stale_before = DateTime.add(now, -@stale_lock_minutes * 60, :second)

    claimable_states =
      if opts[:force?],
        do: @claimable_states ++ ["available", "no_images_found"],
        else: @claimable_states

    {claimed, _} =
      from(c in Chapter,
        where:
          c.id == ^chapter_id and
            (c.status in ^claimable_states or
               (c.status == "processing" and c.locked_at < ^stale_before))
      )
      |> Repo.update_all(set: [status: "processing", locked_at: now, last_attempted_at: now])

    if claimed == 1 do
      {:ok, Repo.get!(Chapter, chapter_id)}
    else
      {:error, :not_claimable}
    end
  end

  defp fetch_series(series_id) do
    if Repo.exists?(from(s in "series", where: s.id == ^series_id)) do
      {:ok, %{id: series_id}}
    else
      {:error, :series_not_found}
    end
  end

  # Deletes previous image rows and their objects so reruns are safe.
  defp reset_existing_images(chapter_id) do
    keys =
      Repo.all(
        from(i in "chapter_images",
          where: i.chapter_id == ^chapter_id and not is_nil(i.storage_key),
          select: i.storage_key
        )
      )

    case Storage.delete_many(keys) do
      :ok ->
        Repo.delete_all(from(i in "chapter_images", where: i.chapter_id == ^chapter_id))
        :ok

      {:error, reason} ->
        {:error, {:storage_cleanup_failed, reason}}
    end
  end

  # -- Pipeline ------------------------------------------------------------------------

  defp process(chapter, series, snapshot, deps) do
    rate_limit = snapshot.config.rate_limit

    with {:ok, html} <- fetch_chapter_page(deps, chapter.source_url, rate_limit),
         {:ok, doc} <- parse(html),
         image_urls <- extract_images(doc, chapter.source_url, snapshot.config) do
      cond do
        image_urls == [] ->
          finalize(chapter, :no_images_found, [])

        length(image_urls) > @max_chapter_images ->
          fail(chapter, "too many images on chapter page: #{length(image_urls)}")

        true ->
          download_all(chapter, series, image_urls, rate_limit, deps)
      end
    else
      {:error, reason} -> fail(chapter, format_reason(reason))
    end
  end

  defp fetch_chapter_page(deps, url, rate_limit) do
    case deps.fetch_html.(url, rate_limit: rate_limit) do
      {:ok, html} -> {:ok, html}
      {:error, reason} -> {:error, {:fetch_failed, reason}}
    end
  end

  defp parse(html) do
    case Floki.parse_document(html) do
      {:ok, doc} -> {:ok, doc}
      {:error, reason} -> {:error, {:parse_failed, reason}}
    end
  end

  defp extract_images(doc, base_url, config) do
    Crysa.Scraping.Parser.extract_image_urls(doc, base_url, config)
  end

  defp download_all(chapter, series, image_urls, rate_limit, deps) do
    results =
      image_urls
      |> Enum.with_index(1)
      |> Enum.map(fn {url, order} -> download_one(deps, url, order, chapter, rate_limit) end)

    failures = Enum.filter(results, &match?({:error, _}, &1))

    stored =
      Enum.flat_map(results, fn
        {:ok, row} -> [row]
        _ -> []
      end)

    if failures == [] do
      persist_and_finalize(chapter, series, stored)
    else
      # Partial success still counts as an error so the chapter is retried;
      # idempotent cleanup makes the retry cheap.
      fail(chapter, "#{length(failures)} of #{length(image_urls)} images failed")
    end
  end

  defp download_one(deps, url, order, chapter, rate_limit) do
    with {:ok, bytes} <- fetch_image(deps, url, rate_limit),
         :ok <- Limits.validate_input(bytes, Limits.defaults()),
         {:ok, webp} <- encode(deps, bytes),
         {:ok, stored} <-
           deps.store.(webp,
             content_type: "image/webp",
             series_id: chapter.series_id,
             chapter_key: chapter.chapter_key,
             image_order: order
           ) do
      {:ok,
       %{
         chapter_id: chapter.id,
         image_order: order,
         source_url: url,
         storage_key: stored.key,
         byte_size: byte_size(webp)
       }}
    else
      {:error, reason} -> {:error, {order, reason}}
    end
  end

  defp fetch_image(deps, url, rate_limit) do
    case deps.fetch_bytes.(url, rate_limit: rate_limit) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, reason} -> {:error, {:fetch_failed, reason}}
    end
  end

  defp encode(deps, bytes) do
    limits = Limits.defaults()

    case Limits.with_timeout(fn -> deps.encode.(bytes, quality: 80) end, limits) do
      {:ok, {:ok, webp}} -> {:ok, webp}
      {:ok, {:error, reason}} -> {:error, {:encode_failed, reason}}
      {:error, :timeout} -> {:error, {:encode_failed, :timeout}}
      {:error, {:encode_crashed, reason}} -> {:error, {:encode_failed, {:crashed, reason}}}
    end
  end

  # -- Finalization ----------------------------------------------------------------------

  defp persist_and_finalize(chapter, series, rows) do
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      {_count, _} =
        Repo.insert_all(
          "chapter_images",
          Enum.map(rows, &Map.merge(&1, %{inserted_at: now, updated_at: now})),
          returning: false
        )

      update_chapter!(chapter.id, %{
        status: "available",
        locked_at: nil,
        last_error: nil,
        published_at: now,
        retry_count: 0
      })

      refresh_series_counters(series.id)
    end)

    Logger.info("chapter downloaded",
      chapter_id: chapter.id,
      series_id: chapter.series_id,
      count: length(rows)
    )

    {:ok, :available}
  end

  defp finalize(chapter, :no_images_found, []) do
    update_chapter!(chapter.id, %{status: "no_images_found", locked_at: nil})
    {:ok, :no_images_found}
  end

  defp fail(chapter, message) do
    update_chapter!(chapter.id, %{
      status: "error",
      locked_at: nil,
      last_error: String.slice(message, 0, @error_truncate),
      # Failure bookkeeping mirrors SeriesCheckWorker.check_retry_count.
      retry_count: (chapter.retry_count || 0) + 1
    })

    Logger.warning("chapter download failed",
      chapter_id: chapter.id,
      series_id: chapter.series_id,
      reason: String.slice(message, 0, 200)
    )

    {:error, {:download_failed, message}}
  end

  defp update_chapter!(chapter_id, attrs) do
    chapter = Repo.get!(Chapter, chapter_id)

    chapter
    |> Chapter.update_changeset(attrs)
    |> Repo.update!()
  end

  # Recomputes derived counters from source-of-truth rows instead of
  # incrementing, so repeated idempotent runs cannot drift.
  defp refresh_series_counters(series_id) do
    {count, latest} =
      Repo.one(
        from(c in Chapter,
          where: c.series_id == ^series_id and c.status == "available",
          select: {count(), max(c.published_at)}
        )
      ) || {0, nil}

    Repo.update_all(
      from(s in "series", where: s.id == ^series_id),
      set: [chapter_count: count, last_chapter_at: latest]
    )
  end

  # -- Helpers ------------------------------------------------------------------------------

  defp format_reason(reason) do
    case reason do
      {:fetch_failed, %{reason: r, status: status}} ->
        "fetch failed: #{inspect(r)}#{if status, do: " (#{status})", else: ""}"

      other ->
        inspect(other)
    end
  end

  # Options may arrive as a keyword list or (in tests) as the injected-deps
  # map; both are accepted for every option.
  defp get_opt(opts, key, default) when is_list(opts), do: Keyword.get(opts, key, default)
  defp get_opt(opts, key, default) when is_map(opts), do: Map.get(opts, key, default)

  defp build_deps(opts) do
    defaults = %{
      fetch_html: fn url, o -> Crysa.Scraping.Fetcher.fetch_html(url, o) end,
      fetch_bytes: fn url, o -> Crysa.Scraping.Fetcher.fetch_bytes(url, o) end,
      encode: &Encoder.to_webp/2,
      store: &Storage.store_chapter_image/2
    }

    Map.merge(defaults, Map.new(opts))
  end
end
