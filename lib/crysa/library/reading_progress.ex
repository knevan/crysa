defmodule Crysa.Library.ReadingProgress do
  @moduledoc """
  Last chapter a user opened per series.

  One row per `(user_id, series_id)` pair, updated on every chapter read.
  Unlike `SeriesViewLog` (append-only analytics with retention cleanup),
  this table is the durable source of truth for "continue reading" and is
  never cleaned up by the view-log job.
  """

  use Ecto.Schema

  import Ecto.Changeset
  alias Crysa.Accounts.User
  alias Crysa.Catalog.{Chapter, Series}

  @type t :: %__MODULE__{}

  schema "user_reading_progress" do
    belongs_to :user, User
    belongs_to :series, Series
    belongs_to :last_chapter, Chapter

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(progress, attrs) do
    progress
    |> cast(attrs, [:user_id, :series_id, :last_chapter_id])
    |> validate_required([:user_id, :series_id, :last_chapter_id])
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:series_id)
    |> foreign_key_constraint(:last_chapter_id)
    |> unique_constraint([:user_id, :series_id])
  end
end
