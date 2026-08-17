defmodule Crysa.Accounts do
  @moduledoc """
  Accounts context for users, roles, profiles, and password reset tokens.
  """

  alias Crysa.Accounts.{PasswordResetToken, Role, User, UserProfile}
  alias Crysa.Repo

  @role_names ~w(superadmin admin moderator user)

  @spec role_names() :: [String.t()]
  def role_names, do: @role_names

  @spec get_role_by_name(String.t()) :: Role.t() | nil
  def get_role_by_name(name), do: Repo.get_by(Role, name: name)

  @spec create_role(map()) :: {:ok, Role.t()} | {:error, Ecto.Changeset.t()}
  def create_role(attrs), do: %Role{} |> Role.changeset(attrs) |> Repo.insert()

  @spec upsert_role!(String.t(), String.t() | nil) :: Role.t()
  def upsert_role!(name, description \\ nil) do
    %Role{}
    |> Role.changeset(%{name: name, description: description})
    |> Repo.insert!(on_conflict: [set: [description: description]], conflict_target: :name)
  end

  @spec create_user(map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def create_user(attrs), do: %User{} |> User.create_changeset(attrs) |> Repo.insert()

  @spec create_profile(map()) :: {:ok, UserProfile.t()} | {:error, Ecto.Changeset.t()}
  def create_profile(attrs), do: %UserProfile{} |> UserProfile.changeset(attrs) |> Repo.insert()

  @spec create_password_reset_token(map()) ::
          {:ok, PasswordResetToken.t()} | {:error, Ecto.Changeset.t()}
  def create_password_reset_token(attrs) do
    %PasswordResetToken{} |> PasswordResetToken.changeset(attrs) |> Repo.insert()
  end
end
