defmodule Crysa.Processing do
  @moduledoc """
  Processing context facade: entry points for scraping/processing flows
  used by admin UIs and internal callers.

  Deletion and repair are modelled as explicit state machines executed by
  durable Oban jobs; these functions only validate, transition the initial
  state and enqueue.
  """

  import Ecto.Query

  alias Crysa.Catalog
  alias Crysa.Processing.Jobs.ChapterRepairWorker
  alias Crysa.Processing.Jobs.SeriesDeletionWorker
  alias Crysa.Repo

  @doc """
  Marks a series `pending_deletion` and enqueues the deletion job.

  Returns `{:error, :already_pending}` when a deletion is already queued or
  running; `{:error, changeset}` for validation failures.
  """
  @spec request_series_deletion(Catalog.Series.t() | integer()) ::
          {:ok, Catalog.Series.t()} | {:error, :already_pending | Ecto.Changeset.t()}
  def request_series_deletion(series_or_id)

  def request_series_deletion(%Catalog.Series{} = series), do: request_series_deletion(series.id)

  def request_series_deletion(series_id) when is_integer(series_id) do
    series = Repo.get!(Catalog.Series, series_id)

    if series.processing_status in ["pending_deletion", "deleting"] do
      {:error, :already_pending}
    else
      with {:ok, series} <-
             Catalog.update_series(series, %{processing_status: "pending_deletion"}) do
        enqueue_deletion(series.id)
        {:ok, series}
      end
    end
  end

  defp enqueue_deletion(series_id) do
    %{series_id: series_id}
    |> SeriesDeletionWorker.new()
    |> Oban.insert()
  end

  @doc """
  Requests a chapter repair, optionally from a replacement source URL.

  The replacement URL must be absolute http(s); host-level config resolution
  happens in the worker. Returns `{:ok, %Oban.Job{}}` or an error tuple.
  """
  @spec request_chapter_repair(integer(), String.t() | nil) ::
          {:ok, Oban.Job.t()} | {:error, term()}
  def request_chapter_repair(chapter_id, new_source_url \\ nil)
      when is_integer(chapter_id) do
    if new_source_url && not valid_url?(new_source_url) do
      {:error, :invalid_replacement_url}
    else
      args =
        if new_source_url,
          do: %{chapter_id: chapter_id, new_source_url: new_source_url},
          else: %{chapter_id: chapter_id}

      args
      |> ChapterRepairWorker.new()
      |> Oban.insert()
    end
  end

  defp valid_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        true

      _ ->
        false
    end
  end

  defp valid_url?(_), do: false

  @doc "Series currently queued for deletion (admin visibility)."
  @spec list_series_pending_deletion() :: [Catalog.Series.t()]
  def list_series_pending_deletion do
    Repo.all(
      from(s in Catalog.Series,
        where: s.processing_status in ["pending_deletion", "deleting", "deletion_failed"],
        order_by: s.updated_at
      )
    )
  end
end
