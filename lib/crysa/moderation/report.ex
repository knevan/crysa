defmodule Crysa.Moderation.Report do
  @moduledoc """
  User report targeting exactly one chapter or comment.
  """

  use Ecto.Schema

  import Ecto.Changeset
  alias Crysa.Accounts.User
  alias Crysa.Catalog.Chapter
  alias Crysa.Comments.Comment
  alias Crysa.Moderation

  @type t :: %__MODULE__{}

  schema "reports" do
    field :reason, :string
    field :details, :string
    field :status, :string, default: "pending"
    field :resolved_at, :utc_datetime
    field :resolution_note, :string

    belongs_to :reporter, User
    belongs_to :chapter, Chapter
    belongs_to :comment, Comment
    belongs_to :resolved_by, User

    timestamps(type: :utc_datetime)
  end

  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(report, attrs) do
    report
    |> cast(attrs, [:reporter_id, :chapter_id, :comment_id, :reason, :details])
    |> validate_required([:reason])
    |> validate_inclusion(:reason, Moderation.report_reasons())
    |> validate_length(:details, max: 4_000)
    |> validate_single_target()
    |> foreign_key_constraint(:reporter_id)
    |> foreign_key_constraint(:chapter_id)
    |> foreign_key_constraint(:comment_id)
    |> check_constraint(:chapter_id, name: :reports_single_target)
  end

  @spec resolution_changeset(t(), map()) :: Ecto.Changeset.t()
  def resolution_changeset(report, attrs) do
    report
    |> cast(attrs, [:status, :resolved_by_id, :resolved_at, :resolution_note])
    |> validate_required([:status, :resolved_by_id, :resolved_at])
    |> validate_inclusion(:status, Moderation.report_statuses())
    |> validate_length(:resolution_note, max: 2_000)
    |> foreign_key_constraint(:resolved_by_id)
  end

  defp validate_single_target(changeset) do
    chapter_id = get_field(changeset, :chapter_id)
    comment_id = get_field(changeset, :comment_id)

    if Enum.count([chapter_id, comment_id], &(!is_nil(&1))) == 1 do
      changeset
    else
      add_error(changeset, :base, "report must target exactly one chapter or comment")
    end
  end
end
