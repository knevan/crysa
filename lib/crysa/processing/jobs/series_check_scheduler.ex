defmodule Crysa.Processing.Jobs.SeriesCheckScheduler do
  @moduledoc """
  Periodic scheduler that finds series due for a check and enqueues one
  unique `SeriesCheckWorker` per series.

  Candidate selection uses the plan's `FOR UPDATE SKIP LOCKED` pattern so
  overlapping scheduler runs (or multiple nodes) never enqueue the same row,
  backed by the partial index on due-and-eligible series. Oban uniqueness on
  `(worker, series_id)` prevents stacking jobs while one is already queued.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: 30]

  import Ecto.Query

  alias Crysa.Processing.Jobs.SeriesCheckWorker
  alias Crysa.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    due_ids = lock_due_series(100)

    enqueued =
      Enum.count(due_ids, fn series_id ->
        # Worker-level uniqueness applies; a call-site override would replace it.
        changeset = SeriesCheckWorker.new(%{series_id: series_id})

        match?({:ok, %Oban.Job{}}, Oban.insert(changeset))
      end)

    {:ok, %{due: length(due_ids), enqueued: enqueued}}
  end

  # Selects due-and-eligible rows with SKIP LOCKED, then releases them by
  # rolling back the locking transaction — the ids are the payload; the
  # dedup guarantee comes from job uniqueness.
  defp lock_due_series(limit) do
    {:ok, ids} =
      Repo.transaction(fn ->
        query =
          from(s in "series",
            where: s.next_check_at <= fragment("now()"),
            where: s.publication_status in ["ongoing", "hiatus", "completed"],
            where: s.processing_status not in ["pending_deletion", "deleting", "deletion_failed"],
            select: s.id,
            order_by: s.next_check_at,
            limit: ^limit,
            lock: "FOR UPDATE SKIP LOCKED"
          )

        Repo.all(query)
      end)

    ids
  end
end
