defmodule Crysa.Comments.Comment do
  @moduledoc """
  Comment targeting either a series or a chapter.
  """

  use Ecto.Schema

  import Ecto.Changeset
  alias Crysa.Accounts.User
  alias Crysa.Catalog.{Chapter, Series}
  alias Crysa.Comments.{Attachment, Vote}

  @type t :: %__MODULE__{}

  schema "comments" do
    field :body_markdown, :string
    field :body_html, :string
    field :deleted_at, :utc_datetime_usec
    field :vote_score, :integer, default: 0

    belongs_to :user, User
    belongs_to :series, Series
    belongs_to :chapter, Chapter
    belongs_to :parent, __MODULE__
    belongs_to :deleted_by, User
    has_many :attachments, Attachment
    has_many :votes, Vote

    timestamps(type: :utc_datetime_usec)
  end

  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(comment, attrs) do
    comment
    |> cast(attrs, [:user_id, :series_id, :chapter_id, :parent_id, :body_markdown, :body_html])
    |> validate_required([:user_id, :body_markdown, :body_html])
    |> validate_length(:body_markdown, min: 1, max: 10_000)
    |> validate_length(:body_html, min: 1, max: 20_000)
    |> validate_single_target()
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:series_id)
    |> foreign_key_constraint(:chapter_id)
    |> foreign_key_constraint(:parent_id)
    |> check_constraint(:series_id, name: :comments_single_target)
  end

  @spec soft_delete_changeset(t(), map()) :: Ecto.Changeset.t()
  def soft_delete_changeset(comment, attrs) do
    comment
    |> cast(attrs, [:deleted_at, :deleted_by_id])
    |> validate_required([:deleted_at, :deleted_by_id])
    |> foreign_key_constraint(:deleted_by_id)
  end

  defp validate_single_target(changeset) do
    series_id = get_field(changeset, :series_id)
    chapter_id = get_field(changeset, :chapter_id)

    if Enum.count([series_id, chapter_id], &(!is_nil(&1))) == 1 do
      changeset
    else
      add_error(changeset, :base, "comment must target exactly one series or chapter")
    end
  end
end
