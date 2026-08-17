defmodule Crysa.Notifications do
  @moduledoc """
  Notifications context for user-facing activity events.
  """

  alias Crysa.Notifications.Notification
  alias Crysa.Repo

  @actions ~w(comment_reply comment_upvote)

  @spec actions() :: [String.t()]
  def actions, do: @actions

  @spec create_notification(map()) :: {:ok, Notification.t()} | {:error, Ecto.Changeset.t()}
  def create_notification(attrs),
    do: %Notification{} |> Notification.changeset(attrs) |> Repo.insert()
end
