defmodule Crysa.Accounts.User do
  @moduledoc """
  Application user account.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Crysa.Accounts.{Role, UserProfile}

  @type t :: %__MODULE__{}

  schema "users" do
    field :email, :string
    field :username, :string
    field :password_hash, :string
    field :active, :boolean, default: true
    field :confirmed_at, :utc_datetime

    belongs_to :role, Role
    has_one :profile, UserProfile

    timestamps(type: :utc_datetime)
  end

  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :username, :password_hash, :role_id, :active, :confirmed_at])
    |> normalize_email_and_username()
    |> validate_required([:email, :username, :password_hash, :role_id])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/)
    |> validate_length(:email, max: 254)
    |> validate_length(:username, min: 3, max: 40)
    |> validate_length(:password_hash, min: 20)
    |> foreign_key_constraint(:role_id)
    |> unique_constraint(:email, name: :users_lower_email_index)
    |> unique_constraint(:username, name: :users_lower_username_index)
  end

  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :username, :role_id, :active, :confirmed_at])
    |> normalize_email_and_username()
    |> validate_required([:email, :username, :role_id, :active])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/)
    |> validate_length(:email, max: 254)
    |> validate_length(:username, min: 3, max: 40)
    |> foreign_key_constraint(:role_id)
    |> unique_constraint(:email, name: :users_lower_email_index)
    |> unique_constraint(:username, name: :users_lower_username_index)
  end

  defp normalize_email_and_username(changeset) do
    changeset
    |> update_change(:email, &normalize_email/1)
    |> update_change(:username, &normalize_username/1)
  end

  defp normalize_email(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize_email(value), do: value

  defp normalize_username(value) when is_binary(value), do: String.trim(value)
  defp normalize_username(value), do: value
end
