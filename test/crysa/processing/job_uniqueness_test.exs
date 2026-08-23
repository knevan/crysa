defmodule Crysa.Processing.JobUniquenessTest do
  @moduledoc """
  Regression tests for terminal-state job uniqueness (review finding P7-1).

  Worker uniqueness must dedup only while a job is unfinished
  (`states: :incomplete, period: :infinity`). With `states: :all`, terminal
  rows persisted by the Pruner window (7 days) silently blocked recurring
  series checks, chapter re-downloads and repairs.
  """

  use Crysa.DataCase, async: false

  import Crysa.CatalogFixtures
  import Ecto.Query

  alias Crysa.Processing.Jobs.{ChapterDownloadWorker, SeriesCheckWorker}
  alias Crysa.Repo

  describe "SeriesCheckWorker uniqueness" do
    test "allows a new insert after the previous job completes" do
      series = series_fixture(%{})

      {:ok, job1} =
        Oban.insert(SeriesCheckWorker.new(%{"series_id" => series.id}))

      finish_job(job1, "completed")

      {:ok, job2} = Oban.insert(SeriesCheckWorker.new(%{"series_id" => series.id}))

      refute job2.conflict?
      refute job2.id == job1.id
    end

    test "allows a new insert after the previous job is discarded" do
      series = series_fixture(%{})

      {:ok, job1} = Oban.insert(SeriesCheckWorker.new(%{"series_id" => series.id}))

      finish_job(job1, "discarded")

      {:ok, job2} = Oban.insert(SeriesCheckWorker.new(%{"series_id" => series.id}))

      refute job2.conflict?
    end

    test "still dedups while a job is unfinished" do
      series = series_fixture(%{})

      {:ok, job1} = Oban.insert(SeriesCheckWorker.new(%{"series_id" => series.id}))

      {:ok, job2} = Oban.insert(SeriesCheckWorker.new(%{"series_id" => series.id}))

      assert job2.conflict?
      assert job2.id == job1.id
    end
  end

  describe "ChapterDownloadWorker uniqueness" do
    test "allows re-enqueue after completion (e.g. chapter reset to error)" do
      series = series_fixture(%{})
      chapter = chapter_fixture(series, %{})

      {:ok, job1} = Oban.insert(ChapterDownloadWorker.new(%{"chapter_id" => chapter.id}))

      finish_job(job1, "completed")

      {:ok, job2} = Oban.insert(ChapterDownloadWorker.new(%{"chapter_id" => chapter.id}))

      refute job2.conflict?
    end
  end

  defp finish_job(job, state) do
    {_, _} =
      from(j in Oban.Job, where: j.id == ^job.id)
      |> Repo.update_all(
        set: [
          state: state,
          completed_at: DateTime.utc_now(),
          discarded_at: if(state == "discarded", do: DateTime.utc_now(), else: nil)
        ]
      )
  end
end
