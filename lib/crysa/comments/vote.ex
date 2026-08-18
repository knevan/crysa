defmodule Crysa.Comments.Vote do
  @moduledoc """
  Single upvote or downvote by a user on a comment.
  """

  use Ecto.Schema

  import Ecto.Changeset
  alias Crysa.Accounts.User
  alias Crysa.Comments.Comment

  @primary_key false
  @type t :: %__MODULE__{}

  schema "comment_votes" do
    field :vote, :integer

    belongs_to :user, User, primary_key: true
    belongs_to :comment, Comment, primary_key: true

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(vote, attrs) do
    vote
    |> cast(attrs, [:user_id, :comment_id, :vote])
    |> validate_required([:user_id, :comment_id, :vote])
    |> validate_inclusion(:vote, [-1, 1])
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:comment_id)
    |> unique_constraint([:user_id, :comment_id], name: :comment_votes_pkey)
    |> check_constraint(:vote, name: :comment_votes_vote_value)
  end
end
