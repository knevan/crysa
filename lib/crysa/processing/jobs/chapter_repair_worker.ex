defmodule Crysa.Processing.Jobs.ChapterRepairWorker do
  @moduledoc """
  Repairs a chapter by re-running the (idempotent) download pipeline,
  optionally from a replacement source URL.

  Port of Castra's `repair_chapter_worker`: old image rows and storage
  objects are removed first, then the chapter is re-downloaded. The
  replacement URL must match the host of an enabled scraping site so the
  correct config is applied.
  """

  use Oban.Worker,
    queue: :chapter_downloads,
    max_attempts: 3,
    unique: [keys: [:chapter_id], states: :incomplete, period: :infinity]

  import Ecto.Query

  alias Crysa.Catalog
  alias Crysa.Processing.ChapterDownload
  alias Crysa.Repo
  alias Crysa.Scraping

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"chapter_id" => chapter_id, "new_source_url" => new_url}})
      when is_binary(new_url) do
    with {:ok, snapshot} <- resolve_snapshot_for_url(new_url),
         :ok <- replace_source_url(chapter_id, new_url) do
      ChapterDownload.run(chapter_id, snapshot, force?: true)
    end
  end

  def perform(%Oban.Job{args: %{"chapter_id" => chapter_id}}) do
    case fetch_source_url(chapter_id) do
      nil ->
        {:error, :chapter_not_found}

      url ->
        with {:ok, snapshot} <- resolve_snapshot_for_url(url) do
          ChapterDownload.run(chapter_id, snapshot, force?: true)
        end
    end
  end

  # -- helpers -----------------------------------------------------------------

  defp fetch_source_url(chapter_id) do
    Repo.one(from(c in "series_chapters", where: c.id == ^chapter_id, select: c.source_url))
  end

  defp replace_source_url(chapter_id, new_url) do
    chapter = Repo.get!(Catalog.Chapter, chapter_id)

    case Catalog.update_chapter(chapter, %{source_url: new_url}) do
      {:ok, _} -> :ok
      {:error, %Ecto.Changeset{} = cs} -> {:error, {:invalid_replacement_url, inspect(cs.errors)}}
    end
  end

  defp resolve_snapshot_for_url(url) do
    host = URI.parse(url || "") |> Map.get(:host)

    case Scraping.published_config_for_host(host || "unknown") do
      {:ok, snapshot} -> {:ok, snapshot}
      {:error, reason} -> {:error, {:no_site_config, reason}}
    end
  end
end
