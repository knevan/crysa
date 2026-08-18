defmodule Crysa.AccountsFixtures do
  @moduledoc """
  Test fixtures for accounts, roles, and users.
  """

  alias Crysa.Accounts
  alias Crysa.Accounts.{Role, User}
  alias Crysa.Repo

  @password "password123"
  @register_password "password1234"
  @password_hash "$argon2id$v=19$m=65536,t=3,p=4$78JyFzqWW/mw6Qu/eRX4Cg$nEBInAvysn57TBn13d2VFi7Hr93Zm5VI2Bel5vvqNJk"

  @spec password() :: String.t()
  def password, do: @password

  @spec password_hash() :: String.t()
  def password_hash, do: @password_hash

  @spec register_password() :: String.t()
  def register_password, do: @register_password

  @spec unique_email() :: String.t()
  def unique_email, do: "user#{System.unique_integer([:positive])}@example.com"

  @spec unique_username() :: String.t()
  def unique_username, do: "user#{System.unique_integer([:positive])}"

  @spec role(String.t()) :: Role.t()
  def role(name \\ "user") do
    case Repo.get_by(Role, name: name) do
      nil -> Repo.insert!(%Role{} |> Ecto.Changeset.change(%{name: name}))
      role -> role
    end
  end

  @doc """
  Creates a user quickly without Argon2 hashing by using a precomputed hash.
  The plaintext password is always `password/0`. Accepts `:role_name` or
  `:role_id` to control the assigned role.
  """
  @spec user_fixture(map()) :: User.t()
  def user_fixture(attrs \\ %{}) do
    role_id = Map.get(attrs, :role_id) || role(Map.get(attrs, :role_name, "user")).id

    defaults = %{
      email: unique_email(),
      username: unique_username(),
      password_hash: @password_hash,
      role_id: role_id,
      active: true
    }

    attrs =
      attrs
      |> Map.put(:role_id, role_id)
      |> Map.delete(:role_name)

    user = Repo.insert!(%User{} |> Ecto.Changeset.change(Map.merge(defaults, attrs)))
    Repo.preload(user, :role)
  end

  @doc "Registers a user through the real registration flow (hashes with Argon2)."
  @spec register_user_fixture(map()) :: User.t()
  def register_user_fixture(attrs \\ %{}) do
    attrs =
      Map.merge(
        %{email: unique_email(), username: unique_username(), password: @register_password},
        attrs
      )

    {:ok, user} =
      Accounts.register_user(Map.put_new(attrs, :password_confirmation, @register_password))

    user
  end
end
