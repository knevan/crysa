defmodule Crysa.Processing.Jobs.SeriesDeletionWorker do
  @moduledoc """
  Deletes a series and all of its stored objects.

  Explicit state machine (plan requirement): `pending_deletion → deleting →
  deleted` with `deletion_failed` as the recoverable error state. Storage
  deletion is idempotent and chunked (`Crysa.Storage.delete_many/1`) and
  happens outside any database transaction; the final row delete cascades
  to chapters, images, comments and related rows.
  """

  use Oban.Worker,
    queue: :deletions,
    max_attempts: 5,
    unique: [keys: [:series_id], states: :incomplete, period: :infinity]

  import Ecto.Query

  require Logger

  alias Crysa.Catalog
  alias Crysa.Repo
  alias Crysa.Storage

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"series_id" => series_id}}) when is_integer(series_id) do
    case claim(series_id) do
      {:ok, series} ->
        delete_series(series)

      {:error, :not_pending_deletion} ->
        {:ok, :not_pending_deletion}
    end
  end

  defp claim(series_id) do
    {claimed, _} =
      from(s in Catalog.Series,
        where: s.id == ^series_id and s.processing_status == "pending_deletion"
      )
      |> Repo.update_all(set: [processing_status: "deleting"])

    if claimed == 1 do
      {:ok, Repo.get!(Catalog.Series, series_id)}
    else
      {:error, :not_pending_deletion}
    end
  end

  defp delete_series(series) do
    keys = storage_keys(series)

    case Storage.delete_many(keys) do
      :ok ->
        case Repo.delete(series) do
          {:ok, _} ->
            Logger.info("series deleted", series_id: series.id, objects: length(keys))
            :ok

          {:error, changeset} ->
            mark_failed(series, inspect(changeset.errors))
            {:error, :db_delete_failed}
        end

      {:error, reason} ->
        mark_failed(series, inspect(reason))
        {:error, {:storage_delete_failed, reason}}
    end
  end

  defp storage_keys(series) do
    image_keys =
      Repo.all(
        from(i in "chapter_images",
          join: c in "series_chapters",
          on: c.id == i.chapter_id,
          where: c.series_id == ^series.id and not is_nil(i.storage_key),
          select: i.storage_key
        )
      )

    cover_key =
      case series.cover_url && Storage.key_from_url(series.cover_url) do
        {:ok, key} -> [key]
        _ -> []
      end

    Enum.uniq(image_keys ++ cover_key)
  end

  defp mark_failed(series, message) do
    Catalog.update_series(series, %{
      processing_status: "deletion_failed",
      last_error: String.slice(message, 0, 2_000)
    })
  end
end
