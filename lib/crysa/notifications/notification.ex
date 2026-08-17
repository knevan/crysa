defmodule Crysa.Notifications.Notification do
  @moduledoc """
  Notification delivered to a recipient user.
  """

  use Ecto.Schema

  import Ecto.Changeset
  alias Crysa.Accounts.User
  alias Crysa.Comments.Comment
  alias Crysa.Notifications

  @type t :: %__MODULE__{}

  schema "notifications" do
    field :action, :string
    field :read_at, :utc_datetime

    belongs_to :recipient, User
    belongs_to :actor, User
    belongs_to :comment, Comment

    timestamps(type: :utc_datetime)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(notification, attrs) do
    notification
    |> cast(attrs, [:recipient_id, :actor_id, :comment_id, :action, :read_at])
    |> validate_required([:recipient_id, :action])
    |> validate_inclusion(:action, Notifications.actions())
    |> check_constraint(:action, name: :notifications_action_check)
    |> foreign_key_constraint(:recipient_id)
    |> foreign_key_constraint(:actor_id)
    |> foreign_key_constraint(:comment_id)
  end
end
