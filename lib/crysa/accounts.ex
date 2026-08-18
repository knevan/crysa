defmodule Crysa.Accounts do
  @moduledoc """
  Accounts context for users, roles, sessions, password resets, and profiles.
  """

  import Ecto.Query

  alias Crysa.Accounts.{PasswordResetToken, Role, User, UserProfile, UsersToken}
  alias Crysa.Repo

  @role_names ~w(superadmin admin moderator user)
  @reset_token_validity_in_hours 1

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

  @doc "Returns the role assigned to newly registered users, creating it if missing."
  @spec default_role() :: Role.t()
  def default_role do
    case Repo.get_by(Role, name: "user") do
      nil ->
        {:ok, role} = create_role(%{name: "user", description: nil})
        role

      role ->
        role
    end
  end

  ## Password hashing

  @doc "Hashes a plaintext password with Argon2."
  @spec hash_password(String.t()) :: String.t()
  def hash_password(password) when is_binary(password) do
    Argon2.hash_pwd_salt(password)
  end

  @doc "Verifies a plaintext password against its Argon2 hash."
  @spec valid_password?(String.t(), String.t()) :: boolean()
  def valid_password?(password, hash) when is_binary(password) and is_binary(hash) do
    Argon2.verify_pass(password, hash)
  end

  def valid_password?(_password, _hash), do: false

  ## User lookup

  @spec get_user!(integer()) :: User.t()
  def get_user!(id) do
    Repo.get!(User, id) |> preload_user()
  end

  @spec get_user_by_email(String.t()) :: User.t() | nil
  def get_user_by_email(email) when is_binary(email) do
    email
    |> String.trim()
    |> String.downcase()
    |> then(&Repo.get_by(User, email: &1))
    |> preload_user()
  end

  @spec get_user_by_username(String.t()) :: User.t() | nil
  def get_user_by_username(username) when is_binary(username) do
    Repo.get_by(User, username: username) |> preload_user()
  end

  @doc """
  Finds a user by their email or username.

  Lookup is case-insensitive for email and case-sensitive for username to
  match the underlying database indexes.
  """
  @spec get_user_by_login(String.t()) :: User.t() | nil
  def get_user_by_login(login) when is_binary(login) do
    login = String.trim(login)

    query =
      from u in User,
        where: u.email == ^String.downcase(login) or u.username == ^login,
        limit: 1

    Repo.one(query) |> preload_user()
  end

  @spec get_user_by_login_and_password(String.t(), String.t()) :: User.t() | nil
  def get_user_by_login_and_password(login, password)
      when is_binary(login) and is_binary(password) do
    with %User{} = user <- get_user_by_login(login),
         true <- valid_password?(password, user.password_hash) do
      user
    else
      _ -> nil
    end
  end

  @doc """
  Authenticates a user by login (email or username) and password.

  Returns `{:ok, user}` on success, `{:error, :invalid_credentials}` for a
  wrong login/password pair, and `{:error, :inactive}` for a disabled account.
  """
  @spec authenticate_user(String.t(), String.t()) ::
          {:ok, User.t()} | {:error, :invalid_credentials} | {:error, :inactive}
  def authenticate_user(login, password) do
    case get_user_by_login_and_password(login, password) do
      %User{active: false} -> {:error, :inactive}
      %User{} = user -> {:ok, user}
      nil -> {:error, :invalid_credentials}
    end
  end

  ## Registration

  @doc "Builds the registration changeset for form rendering."
  @spec change_user_registration(User.t() | nil, map()) :: Ecto.Changeset.t()
  def change_user_registration(user \\ %User{}, attrs \\ %{}) do
    User.registration_changeset(user, attrs)
  end

  @doc """
  Registers a new user with the default `user` role and a profile record.

  Returns `{:ok, user}` on success, or `{:error, changeset}` on failure.
  """
  @spec register_user(map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def register_user(attrs) do
    changeset =
      %User{}
      |> User.registration_changeset(attrs)
      |> Ecto.Changeset.put_change(:role_id, default_role().id)

    if changeset.valid?, do: create_user(changeset), else: {:error, changeset}
  end

  @doc """
  Creates a user from trusted bootstrap data (seeds/admin), bypassing the
  public registration policy. The password must arrive as a precomputed
  `password_hash`.
  """
  @spec create_bootstrap_user(map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def create_bootstrap_user(attrs) do
    with {:ok, password_hash} <- require_bootstrap_hash(Map.get(attrs, :password_hash)),
         {:ok, role_id} <- require_bootstrap_role(Map.get(attrs, :role_id)) do
      changeset =
        %User{}
        |> User.identity_changeset(attrs)
        |> Ecto.Changeset.put_change(:password_hash, password_hash)
        |> Ecto.Changeset.put_change(:active, Map.get(attrs, :active, true))
        |> Ecto.Changeset.put_change(:role_id, role_id)

      Repo.insert(changeset)
    end
  end

  defp require_bootstrap_hash(nil), do: {:error, bootstrap_changeset(:password_hash)}

  defp require_bootstrap_hash(hash) when is_binary(hash) and byte_size(hash) > 0,
    do: {:ok, hash}

  defp require_bootstrap_hash(_), do: {:error, bootstrap_changeset(:password_hash)}

  defp require_bootstrap_role(nil), do: {:error, bootstrap_changeset(:role_id)}

  defp require_bootstrap_role(role_id) when is_integer(role_id), do: {:ok, role_id}
  defp require_bootstrap_role(_), do: {:error, bootstrap_changeset(:role_id)}

  defp bootstrap_changeset(field) do
    %Ecto.Changeset{}
    |> Ecto.Changeset.add_error(field, "is required for bootstrap users")
  end

  defp create_user(changeset) do
    case Repo.transaction(fn -> insert_user_and_profile(changeset) end) do
      {:ok, {:ok, user}} -> {:ok, user}
      {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_user_and_profile(changeset) do
    case Repo.insert(changeset) do
      {:ok, user} -> insert_profile_for(user)
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp insert_profile_for(user) do
    case %UserProfile{}
         |> UserProfile.changeset(%{user_id: user.id})
         |> Repo.insert() do
      {:ok, _profile} -> {:ok, preload_user(user)}
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  ## Sessions

  @doc "Generates and persists a session token for the given user."
  @spec generate_user_session_token(User.t()) :: binary()
  def generate_user_session_token(user) do
    {token, user_token} = UsersToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc "Returns the user owning the given session token, or nil."
  @spec get_user_by_session_token(binary()) :: User.t() | nil
  def get_user_by_session_token(token) when is_binary(token) do
    {:ok, query} = UsersToken.verify_session_token_query(token)
    Repo.one(query) |> preload_user()
  end

  @doc "Deletes a single session token."
  @spec delete_user_session_token(binary()) :: :ok
  def delete_user_session_token(token) when is_binary(token) do
    Repo.delete_all(from(t in UsersToken, where: t.token == ^token and t.context == "session"))
    :ok
  end

  @doc "Deletes every session token for the given user."
  @spec delete_all_user_sessions(User.t()) :: :ok
  def delete_all_user_sessions(user) do
    Repo.delete_all(UsersToken.user_sessions_query(user))
    :ok
  end

  ## Password reset

  @doc """
  Creates a reset token with a stored digest, returns the raw token.
  """
  @spec create_reset_token(User.t()) :: {:ok, binary()} | {:error, Ecto.Changeset.t()}
  def create_reset_token(user) do
    raw_bytes = :crypto.strong_rand_bytes(32)
    raw_token = Base.url_encode64(raw_bytes, padding: false)
    digest = :crypto.hash(:sha256, raw_bytes)
    expires_at = DateTime.utc_now() |> DateTime.add(@reset_token_validity_in_hours, :hour)

    case create_password_reset_token(%{
           user_id: user.id,
           token_digest: digest,
           expires_at: expires_at
         }) do
      {:ok, _token} -> {:ok, raw_token}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc "Returns the user for a valid, unused, non-expired reset token, or nil."
  @spec get_user_by_reset_password_token(binary()) :: User.t() | nil
  def get_user_by_reset_password_token(token) when is_binary(token) do
    case Base.url_decode64(token, padding: false) do
      {:ok, decoded} ->
        digest = :crypto.hash(:sha256, decoded)

        query =
          from t in PasswordResetToken,
            join: user in assoc(t, :user),
            where:
              t.token_digest == ^digest and is_nil(t.used_at) and
                t.expires_at > ^DateTime.utc_now(),
            select: user,
            limit: 1

        Repo.one(query) |> preload_user()

      :error ->
        nil
    end
  end

  @doc """
  Resets the user password, invalidates their sessions, and marks the reset
  token as used.

  Returns `{:error, :invalid_token}` when the token does not match the user,
  is expired, or was already used.
  """
  @spec reset_user_password(User.t(), map(), binary()) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t()} | {:error, :invalid_token}
  def reset_user_password(user, attrs, raw_token) do
    with {:ok, digest} <- token_digest(raw_token),
         :ok <- ensure_valid_reset_token(user, digest) do
      changeset = User.password_changeset(user, attrs, require_current_password: false)

      Repo.transaction(fn ->
        user = Repo.update!(changeset)
        Repo.delete_all(UsersToken.user_sessions_query(user))

        Repo.update_all(
          from(t in PasswordResetToken, where: t.token_digest == ^digest and is_nil(t.used_at)),
          set: [used_at: DateTime.utc_now()]
        )

        preload_user(user)
      end)
      |> case do
        {:ok, user} -> {:ok, user}
        {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
        {:error, reason} -> {:error, reason}
      end
    else
      _ -> {:error, :invalid_token}
    end
  end

  defp token_digest(raw_token) do
    case Base.url_decode64(raw_token, padding: false) do
      {:ok, decoded} -> {:ok, :crypto.hash(:sha256, decoded)}
      :error -> :error
    end
  end

  defp ensure_valid_reset_token(user, digest) do
    exists? =
      Repo.exists?(
        from(t in PasswordResetToken,
          where:
            t.user_id == ^user.id and t.token_digest == ^digest and is_nil(t.used_at) and
              t.expires_at > ^DateTime.utc_now()
        )
      )

    if exists?, do: :ok, else: :error
  end

  @doc """
  Updates the password for a logged-in user, requiring the current password.

  All other sessions are invalidated. Pass `keep_session: token` to preserve
  the caller's own session token.
  """
  @spec update_user_password(User.t(), map(), keyword()) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def update_user_password(user, attrs, opts \\ []) do
    with {:ok, user} <- user |> User.password_changeset(attrs) |> Repo.update() do
      delete_other_sessions(user, Keyword.get(opts, :keep_session))
      {:ok, user}
    end
  end

  defp delete_other_sessions(user, nil), do: delete_all_user_sessions(user)

  defp delete_other_sessions(user, keep_token) do
    Repo.delete_all(
      from(t in UsersToken,
        where: t.user_id == ^user.id and t.token != ^keep_token and t.context == "session"
      )
    )

    :ok
  end

  @doc "Builds the password changeset for form rendering."
  @spec change_user_password(User.t(), map()) :: Ecto.Changeset.t()
  def change_user_password(user, attrs \\ %{}) do
    User.password_changeset(user, attrs)
  end

  ## Password reset token CRUD

  @spec create_password_reset_token(map()) ::
          {:ok, PasswordResetToken.t()} | {:error, Ecto.Changeset.t()}
  def create_password_reset_token(attrs) do
    %PasswordResetToken{} |> PasswordResetToken.changeset(attrs) |> Repo.insert()
  end

  @doc "Deletes all expired reset tokens and returns the count deleted."
  @spec delete_expired_reset_tokens() :: non_neg_integer()
  def delete_expired_reset_tokens do
    {count, _} =
      Repo.delete_all(from(t in PasswordResetToken, where: t.expires_at < ^DateTime.utc_now()))

    count
  end

  ## Profiles

  defp preload_user(nil), do: nil

  defp preload_user(%User{} = user) do
    user
    |> Repo.preload(:role)
    |> Repo.preload(:profile)
  end

  @doc "Returns the user profile, creating it if missing."
  @spec get_or_create_profile(User.t()) :: UserProfile.t()
  def get_or_create_profile(%User{} = user) do
    case load_profile(user) do
      nil ->
        {:ok, profile} =
          %UserProfile{}
          |> UserProfile.changeset(%{user_id: user.id})
          |> Repo.insert()

        profile

      profile ->
        profile
    end
  end

  defp load_profile(%User{id: user_id}) do
    Repo.get_by(UserProfile, user_id: user_id)
  end

  @doc "Updates the user profile, creating it if missing."
  @spec update_profile(User.t(), map()) :: {:ok, UserProfile.t()} | {:error, Ecto.Changeset.t()}
  def update_profile(user, attrs) do
    profile = get_or_create_profile(user)

    profile
    |> UserProfile.changeset(attrs)
    |> Repo.update()
  end

  @doc "Builds the profile changeset for form rendering."
  @spec change_profile(User.t(), map()) :: Ecto.Changeset.t()
  def change_profile(user, attrs \\ %{}) do
    get_or_create_profile(user)
    |> UserProfile.changeset(attrs)
  end

  @doc "Deletes all expired session and reset tokens."
  @spec cleanup_expired_tokens() :: non_neg_integer()
  def cleanup_expired_tokens do
    {sessions, _} =
      Repo.delete_all(
        from(t in UsersToken,
          where: t.context == "session" and t.inserted_at < ago(14, "day")
        )
      )

    resets = delete_expired_reset_tokens()
    sessions + resets
  end
end
