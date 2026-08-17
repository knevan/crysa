defmodule Crysa.Moderation do
  @moduledoc """
  Moderation context for user reports and resolution metadata.
  """

  alias Crysa.Moderation.Report
  alias Crysa.Repo

  @report_reasons ~w(
    broken_image wrong_chapter duplicated_chapter missing_image missing_chapter slow_loading
    broken_text toxic racist spam other
  )
  @report_statuses ~w(pending resolved rejected)

  @spec report_reasons() :: [String.t()]
  def report_reasons, do: @report_reasons

  @spec report_statuses() :: [String.t()]
  def report_statuses, do: @report_statuses

  @spec create_report(map()) :: {:ok, Report.t()} | {:error, Ecto.Changeset.t()}
  def create_report(attrs), do: %Report{} |> Report.create_changeset(attrs) |> Repo.insert()
end
