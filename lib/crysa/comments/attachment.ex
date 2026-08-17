defmodule Crysa.Comments.Attachment do
  @moduledoc """
  Stored attachment metadata for a comment.
  """

  use Ecto.Schema

  import Ecto.Changeset
  alias Crysa.Accounts.User
  alias Crysa.Comments.Comment

  @type t :: %__MODULE__{}

  schema "comment_attachments" do
    field :storage_key, :string
    field :content_type, :string
    field :byte_size, :integer

    belongs_to :comment, Comment
    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(attachment, attrs) do
    attachment
    |> cast(attrs, [:comment_id, :user_id, :storage_key, :content_type, :byte_size])
    |> validate_required([:comment_id, :storage_key, :content_type, :byte_size])
    |> validate_length(:storage_key, min: 1, max: 1_024)
    |> validate_length(:content_type, min: 3, max: 120)
    |> validate_number(:byte_size, greater_than: 0)
    |> foreign_key_constraint(:comment_id)
    |> foreign_key_constraint(:user_id)
  end
end
