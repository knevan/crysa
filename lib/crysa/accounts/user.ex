defmodule Crysa.Accounts.User do
  @moduledoc """
  Application user account.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Crysa.Accounts.{Role, UserProfile, UsersToken}

  @password_min_length 12
  @password_max_length 72

  @type t :: %__MODULE__{}

  schema "users" do
    field :email, :string
    field :username, :string
    field :password, :string, virtual: true
    field :password_confirmation, :string, virtual: true
    field :current_password, :string, virtual: true
    field :password_hash, :string
    field :active, :boolean, default: true
    field :confirmed_at, :utc_datetime_usec

    belongs_to :role, Role
    has_one :profile, UserProfile
    has_many :tokens, UsersToken

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Maximum accepted password length in bytes (Argon2 input limit)."
  @spec password_max_length() :: pos_integer()
  def password_max_length, do: @password_max_length

  @doc "Minimum accepted password length."
  @spec password_min_length() :: pos_integer()
  def password_min_length, do: @password_min_length

  @doc """
  Builds the changeset used for public registration.
  """
  @spec registration_changeset(t(), map()) :: Ecto.Changeset.t()
  def registration_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :username, :password, :password_confirmation])
    |> validate_required([:email, :username, :password, :password_confirmation])
    |> validate_registration()
    |> put_password_hash()
  end

  @doc """
  Builds the changeset used to change the account password.
  """
  @spec password_changeset(t(), map(), keyword()) :: Ecto.Changeset.t()
  def password_changeset(user, attrs, opts \\ []) do
    changeset =
      user
      |> cast(attrs, [:current_password, :password, :password_confirmation])
      |> validate_required([:password, :password_confirmation])
      |> validate_confirmation(:password, message: "does not match password")
      |> validate_password_policy()
      |> put_password_hash()

    case Keyword.get(opts, :require_current_password, true) do
      true ->
        changeset
        |> validate_required([:current_password])
        |> validate_current_password(get_change(changeset, :current_password))

      false ->
        changeset
    end
  end

  @doc """
  Builds a changeset that only normalizes account identity fields.
  """
  @spec identity_changeset(t(), map()) :: Ecto.Changeset.t()
  def identity_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :username])
    |> normalize_email_and_username()
    |> validate_required([:email, :username])
    |> validate_email_format()
    |> validate_username()
    |> unique_constraint(:email, name: :users_lower_email_index)
    |> unique_constraint(:username, name: :users_lower_username_index)
  end

  defp validate_registration(changeset) do
    changeset
    |> normalize_email_and_username()
    |> validate_email_format()
    |> validate_username()
    |> validate_confirmation(:password, message: "does not match password")
    |> validate_password_policy()
    |> unique_constraint(:email, name: :users_lower_email_index)
    |> unique_constraint(:username, name: :users_lower_username_index)
  end

  defp validate_password_policy(changeset) do
    changeset
    |> validate_length(:password, min: @password_min_length, max: @password_max_length)
    |> validate_format(:password, ~r/[a-zA-Z]/, message: "must contain at least one letter")
    |> validate_format(:password, ~r/\d/, message: "must contain at least one digit")
  end

  defp put_password_hash(changeset) do
    case get_change(changeset, :password) do
      nil ->
        changeset

      password ->
        if valid_password?(password) do
          put_change(changeset, :password_hash, Crysa.Accounts.hash_password(password))
        else
          changeset
        end
    end
  end

  defp validate_current_password(changeset, nil), do: changeset

  defp validate_current_password(changeset, current_password) do
    if Crysa.Accounts.valid_password?(current_password, changeset.data.password_hash) do
      changeset
    else
      add_error(changeset, :current_password, "is incorrect")
    end
  end

  defp valid_password?(password) when is_binary(password),
    do: byte_size(password) in @password_min_length..@password_max_length

  defp valid_password?(_password), do: false

  defp normalize_email_and_username(changeset) do
    changeset
    |> update_change(:email, &normalize_email/1)
    |> update_change(:username, &normalize_username/1)
  end

  defp normalize_email(value) when is_binary(value),
    do: value |> String.trim() |> String.downcase()

  defp normalize_email(value), do: value

  defp normalize_username(value) when is_binary(value), do: String.trim(value)
  defp normalize_username(value), do: value

  defp validate_email_format(changeset) do
    changeset
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/, message: "must have the @ sign and no spaces")
    |> validate_length(:email, max: 254)
  end

  defp validate_username(changeset) do
    changeset
    |> validate_format(:username, ~r/^[a-zA-Z0-9_]+$/,
      message: "may only contain letters, numbers, and underscores"
    )
    |> validate_length(:username, min: 3, max: 40)
  end
end
