defmodule Crysa.Library do
  @moduledoc """
  Library context for bookmarks, ratings, and series view events.
  """

  alias Crysa.Library.{Bookmark, Rating, SeriesViewLog}
  alias Crysa.Repo

  @spec create_bookmark(map()) :: {:ok, Bookmark.t()} | {:error, Ecto.Changeset.t()}
  def create_bookmark(attrs), do: %Bookmark{} |> Bookmark.changeset(attrs) |> Repo.insert()

  @spec create_rating(map()) :: {:ok, Rating.t()} | {:error, Ecto.Changeset.t()}
  def create_rating(attrs), do: %Rating{} |> Rating.changeset(attrs) |> Repo.insert()

  @spec create_view_log(map()) :: {:ok, SeriesViewLog.t()} | {:error, Ecto.Changeset.t()}
  def create_view_log(attrs), do: %SeriesViewLog{} |> SeriesViewLog.changeset(attrs) |> Repo.insert()
end
