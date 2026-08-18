defmodule Crysa.Library.Bookmark do
  @moduledoc """
  User bookmark for a series.
  """

  use Ecto.Schema

  import Ecto.Changeset
  alias Crysa.Accounts.User
  alias Crysa.Catalog.Series

  @type t :: %__MODULE__{}

  schema "user_bookmarks" do
    belongs_to :user, User
    belongs_to :series, Series

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(bookmark, attrs) do
    bookmark
    |> cast(attrs, [:user_id, :series_id])
    |> validate_required([:user_id, :series_id])
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:series_id)
    |> unique_constraint([:user_id, :series_id])
  end
end
