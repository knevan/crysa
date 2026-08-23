defmodule Crysa.Processing.Jobs.ChapterDownloadWorker do
  @moduledoc """
  Downloads, encodes (WebP) and stores a single chapter.

  Uniqueness on `chapter_id` prevents duplicate concurrent downloads of the
  same chapter; the pipeline itself is idempotent so Oban retries are safe.
  """

  use Oban.Worker,
    queue: :chapter_downloads,
    max_attempts: 5,
    unique: [keys: [:chapter_id], states: :incomplete, period: :infinity]

  import Ecto.Query

  alias Crysa.Processing.ChapterDownload
  alias Crysa.Repo
  alias Crysa.Scraping

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"chapter_id" => chapter_id}}) when is_integer(chapter_id) do
    with {:ok, snapshot} <- resolve_snapshot(chapter_id) do
      ChapterDownload.run(chapter_id, snapshot)
    end
  end

  defp resolve_snapshot(chapter_id) do
    source_url =
      Repo.one(
        from(c in "series_chapters",
          join: s in "series",
          on: s.id == c.series_id,
          where: c.id == ^chapter_id,
          select: s.source_url
        )
      )

    case source_url do
      nil ->
        {:error, :chapter_not_found}

      url ->
        host = URI.parse(url || "") |> Map.get(:host)

        case Scraping.published_config_for_host(host || "unknown") do
          {:ok, snapshot} -> {:ok, snapshot}
          {:error, reason} -> {:error, {:no_site_config, reason}}
        end
    end
  end
end
