defmodule Crysa.Comments do
  @moduledoc """
  Comments context for comment threads, attachments, and votes.
  """

  alias Crysa.Comments.{Attachment, Comment, Vote}
  alias Crysa.Repo

  @spec create_comment(map()) :: {:ok, Comment.t()} | {:error, Ecto.Changeset.t()}
  def create_comment(attrs), do: %Comment{} |> Comment.create_changeset(attrs) |> Repo.insert()

  @spec create_attachment(map()) :: {:ok, Attachment.t()} | {:error, Ecto.Changeset.t()}
  def create_attachment(attrs), do: %Attachment{} |> Attachment.changeset(attrs) |> Repo.insert()

  @spec create_vote(map()) :: {:ok, Vote.t()} | {:error, Ecto.Changeset.t()}
  def create_vote(attrs), do: %Vote{} |> Vote.changeset(attrs) |> Repo.insert()
end
