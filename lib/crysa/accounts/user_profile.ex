defmodule Crysa.Accounts.UserProfile do
  @moduledoc """
  Optional profile data for a user.
  """

  use Ecto.Schema

  import Ecto.Changeset
  alias Crysa.Accounts.User

  @type t :: %__MODULE__{}

  schema "user_profiles" do
    field :display_name, :string
    field :avatar_url, :string

    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(profile, attrs) do
    profile
    |> cast(attrs, [:user_id, :display_name, :avatar_url])
    |> update_change(:display_name, &trim/1)
    |> validate_required([:user_id])
    |> validate_length(:display_name, max: 80)
    |> validate_length(:avatar_url, max: 2_048)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:user_id)
  end

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value
end
