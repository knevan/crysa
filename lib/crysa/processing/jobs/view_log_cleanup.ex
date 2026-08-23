defmodule Crysa.Processing.Jobs.ViewLogCleanup do
  @moduledoc """
  Deletes old `series_view_log` rows beyond the retention window.

  The view log is a write-behind aggregate source; once aggregates are
  reconciled (or the retention window passes), raw events are no longer
  needed. Default retention: 90 days.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  import Ecto.Query

  alias Crysa.Repo

  @default_retention_days 90

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    retention_days = retention_days()
    cutoff = DateTime.add(DateTime.utc_now(), -retention_days, :day)

    {deleted, _} =
      from(v in "series_view_log", where: v.inserted_at < ^cutoff)
      |> Repo.delete_all()

    {:ok, %{deleted: deleted, retention_days: retention_days}}
  end

  defp retention_days do
    :crysa
    |> Application.get_env(Crysa.Processing, [])
    |> Keyword.get(:view_log_retention_days, @default_retention_days)
  end
end
