defmodule Crysa.Accounts do
  @moduledoc """
  Accounts context for users, roles, sessions, password resets, and profiles.
  """

  import Ecto.Query

  alias Crysa.Accounts.{PasswordResetToken, Role, User, UserProfile, UsersToken}
  alias Crysa.Repo
  alias Crysa.Storage

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

  @doc "Builds the self-service email changeset for form rendering."
  @spec change_user_email(User.t(), map()) :: Ecto.Changeset.t()
  def change_user_email(%User{} = user, attrs \\ %{}) do
    User.email_changeset(user, attrs)
  end

  @doc """
  Updates the email address for a logged-in user.

  Returns `{:ok, user}` on success, or `{:error, changeset}` when the
  address is invalid or already taken.
  """
  @spec update_user_email(User.t(), map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def update_user_email(%User{} = user, attrs) do
    user
    |> User.email_changeset(attrs)
    |> Repo.update()
    |> case do
      {:ok, updated} -> {:ok, preload_user(updated)}
      {:error, changeset} -> {:error, changeset}
    end
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

  @doc """
  Resolves the public avatar URL for a profile from its stored storage key.

  The database holds the opaque storage key; URL construction happens here
  at the presentation boundary so stored data stays identical across
  environments.
  """
  @spec avatar_url(UserProfile.t() | nil) :: String.t() | nil
  def avatar_url(%UserProfile{avatar_key: key}) when is_binary(key) and key != "",
    do: Storage.url_for(key)

  def avatar_url(_), do: nil

  @admin_default_page_size 25
  @admin_max_page_size 100
  @max_search_length 100

  @doc """
  Admin user listing for the dashboard TanStack table.

  Search is `ILIKE` on `username` and `email` (wildcard-escaped),
  ordering is stable `inserted_at DESC, id DESC`. Pagination defaults to
  25 and is clamped to `1..50`.
  """
  @spec admin_list_users(map()) :: {[User.t()], Crysa.Pagination.t()}
  def admin_list_users(params \\ %{}) when is_map(params) do
    q = parse_admin_search(params)
    page = parse_admin_page(params)
    page_size = parse_admin_page_size(params)

    base =
      from(u in User, as: :user)
      |> filter_admin_users(q)
      |> order_by([u], desc: u.inserted_at, desc: u.id)

    total = Repo.aggregate(base, :count, :id)
    page = clamp_admin_page(page, page_size, total)

    users =
      base
      |> preload([:role])
      |> limit(^page_size)
      |> offset(^((page - 1) * page_size))
      |> Repo.all()

    {users, Crysa.Pagination.build(page, page_size, total)}
  end

  defp parse_admin_search(%{"q" => q}) when is_binary(q) do
    case q |> String.trim() |> String.slice(0, @max_search_length) do
      "" -> nil
      term -> term
    end
  end

  defp parse_admin_search(%{q: q}) when is_binary(q) do
    case q |> String.trim() |> String.slice(0, @max_search_length) do
      "" -> nil
      term -> term
    end
  end

  defp parse_admin_search(_), do: nil

  defp filter_admin_users(query, nil), do: query

  defp filter_admin_users(query, term) do
    pattern = "%#{escape_admin_like(term)}%"
    where(query, [u], ilike(u.username, ^pattern) or ilike(u.email, ^pattern))
  end

  defp escape_admin_like(term) when is_binary(term) do
    term
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  defp parse_admin_page(params) do
    case parse_admin_integer(params, "page", 1) do
      page when page > 0 -> page
      _ -> 1
    end
  end

  defp parse_admin_page_size(params) do
    params
    |> parse_admin_integer("page_size", @admin_default_page_size)
    |> clamp_admin(1, @admin_max_page_size)
  end

  defp parse_admin_integer(params, key, default) do
    case params do
      %{^key => value} when is_integer(value) ->
        value

      %{^key => value} when is_binary(value) ->
        case Integer.parse(value) do
          {int, ""} -> int
          _ -> default
        end

      _ ->
        default
    end
  end

  defp clamp_admin_page(page, page_size, total) do
    total_pages = max(div(total + page_size - 1, page_size), 1)
    min(page, total_pages)
  end

  defp clamp_admin(value, min, _max) when value < min, do: min
  defp clamp_admin(value, _min, max) when value > max, do: max
  defp clamp_admin(value, _min, _max), do: value

  @role_levels %{"user" => 1, "moderator" => 2, "admin" => 3, "superadmin" => 4}

  @doc """
  Admin update for a target user.

  Enforces hierarchy rules mirroring Castra but without its gaps:

    * Actor cannot update themselves.
    * Actor's role level must be strictly higher than the target's current level.
    * When changing role, the new role level must be strictly lower than the actor's level.
    * Username/email conflicts are reported as changeset errors.

  `attrs` may contain string or atom keys: `"username"`, `"email"`,
  `"role"` (name string), `"role_id"` (integer), `"active"`/`"is_active"`
  (boolean). Unknown keys are ignored.

  Returns `{:ok, user}`, `{:error, :not_found}`, `{:error, :cannot_update_self}`,
  `{:error, :forbidden}`, `{:error, :cannot_assign_higher_role}` or
  `{:error, changeset}`.
  """
  @spec admin_update_user(integer(), map(), User.t()) ::
          {:ok, User.t()}
          | {:error, :not_found}
          | {:error, :cannot_update_self}
          | {:error, :forbidden}
          | {:error, :cannot_assign_higher_role}
          | {:error, :invalid_role}
          | {:error, Ecto.Changeset.t()}
  def admin_update_user(target_id, attrs, %User{} = actor)
      when is_integer(target_id) and is_map(attrs) do
    actor_role = actor_role_name(actor)
    actor_level = Map.get(@role_levels, actor_role, 0)

    Repo.transaction(fn ->
      target =
        Repo.one(from(u in User, where: u.id == ^target_id, lock: "FOR UPDATE", preload: [:role]))

      cond do
        is_nil(target) ->
          Repo.rollback(:not_found)

        actor.id == target.id ->
          Repo.rollback(:cannot_update_self)

        true ->
          target_role = target_role_name(target)
          target_level = Map.get(@role_levels, target_role, 0)

          if actor_level <= target_level do
            Repo.rollback(:forbidden)
          else
            normalized = normalize_admin_attrs(attrs)

            case resolve_admin_role(normalized, actor_level) do
              {:ok, role_id_or_nil} ->
                changes = build_admin_changes(normalized, role_id_or_nil)

                if map_size(changes) == 0 do
                  preload_user(target)
                else
                  changeset = User.admin_changeset(target, changes)

                  case Repo.update(changeset) do
                    {:ok, updated} -> preload_user(updated)
                    {:error, changeset} -> Repo.rollback(changeset)
                  end
                end

              {:error, reason} ->
                Repo.rollback(reason)
            end
          end
      end
    end)
    |> case do
      {:ok, user} when is_struct(user, User) -> {:ok, user}
      {:error, %Ecto.Changeset{} = cs} -> {:error, cs}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Admin deletion of a target user.

  Hierarchy rules are identical to `admin_update_user/3`: cannot delete
  self, cannot delete equal or higher role.

  Sessions for the target are removed atomically with the user row.
  """
  @spec admin_delete_user(integer(), User.t()) ::
          {:ok, User.t()} | {:error, :not_found | :cannot_delete_self | :forbidden}
  def admin_delete_user(target_id, %User{} = actor) when is_integer(target_id) do
    actor_role = actor_role_name(actor)
    actor_level = Map.get(@role_levels, actor_role, 0)

    Repo.transaction(fn ->
      target =
        Repo.one(from(u in User, where: u.id == ^target_id, lock: "FOR UPDATE", preload: [:role]))

      cond do
        is_nil(target) ->
          Repo.rollback(:not_found)

        actor.id == target.id ->
          Repo.rollback(:cannot_delete_self)

        true ->
          target_role = target_role_name(target)
          target_level = Map.get(@role_levels, target_role, 0)

          if actor_level <= target_level do
            Repo.rollback(:forbidden)
          else
            # Remove sessions first; FK cascades handle bookmarks etc.,
            # but token rows should be cleared explicitly for clarity.
            Repo.delete_all(from(t in UsersToken, where: t.user_id == ^target.id))
            # Password reset digests are also cleared; on_delete is delete_all
            # but we delete explicitly to keep the transaction tight.
            Repo.delete_all(from(t in PasswordResetToken, where: t.user_id == ^target.id))

            case Repo.delete(target) do
              {:ok, deleted} -> deleted
              {:error, cs} -> Repo.rollback(cs)
            end
          end
      end
    end)
    |> case do
      {:ok, user} -> {:ok, user}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      {:error, %Ecto.Changeset{} = cs} -> {:error, cs}
    end
  end

  defp actor_role_name(%User{role: %Role{name: name}}) when is_binary(name), do: name

  defp actor_role_name(%User{role_id: role_id}) when is_integer(role_id) do
    case Repo.get(Role, role_id) do
      %Role{name: name} -> name
      _ -> "user"
    end
  end

  defp actor_role_name(_), do: "user"

  defp target_role_name(%User{role: %Role{name: name}}) when is_binary(name), do: name
  defp target_role_name(%User{role: %{} = role}), do: Map.get(role, :name, "user")
  defp target_role_name(_), do: "user"

  defp normalize_admin_attrs(attrs) when is_map(attrs) do
    Enum.reduce(attrs, %{}, fn {k, v}, acc ->
      key =
        case k do
          k when is_atom(k) -> Atom.to_string(k)
          k when is_binary(k) -> k
          _ -> to_string(k)
        end

      Map.put(acc, key, v)
    end)
  end

  defp resolve_admin_role(normalized, actor_level) do
    cond do
      Map.has_key?(normalized, "role") ->
        raw = normalized["role"]

        name =
          raw
          |> to_string()
          |> String.trim()
          |> String.downcase()

        cond do
          name == "" ->
            {:ok, nil}

          name not in @role_names ->
            {:error, :invalid_role}

          Map.get(@role_levels, name, 0) >= actor_level ->
            {:error, :cannot_assign_higher_role}

          true ->
            case Repo.get_by(Role, name: name) do
              %Role{id: id} -> {:ok, id}
              nil -> {:error, :invalid_role}
            end
        end

      Map.has_key?(normalized, "role_id") ->
        raw = normalized["role_id"]

        role_id =
          case raw do
            id when is_integer(id) ->
              id

            bin when is_binary(bin) ->
              case Integer.parse(bin) do
                {int, ""} -> int
                _ -> nil
              end

            _ ->
              nil
          end

        if is_nil(role_id) do
          {:ok, nil}
        else
          case Repo.get(Role, role_id) do
            %Role{name: name} ->
              if Map.get(@role_levels, name, 0) >= actor_level do
                {:error, :cannot_assign_higher_role}
              else
                {:ok, role_id}
              end

            nil ->
              {:error, :invalid_role}
          end
        end

      true ->
        {:ok, :no_change}
    end
  end

  defp build_admin_changes(normalized, role_id_or_nil) do
    changes = %{}

    changes =
      case Map.get(normalized, "username") do
        nil ->
          case Map.get(normalized, "userName") do
            nil -> changes
            v when is_binary(v) -> Map.put(changes, :username, String.trim(v))
            _ -> changes
          end

        v when is_binary(v) ->
          trimmed = String.trim(v)
          if trimmed == "", do: changes, else: Map.put(changes, :username, trimmed)

        _ ->
          changes
      end

    changes =
      case Map.get(normalized, "email") do
        nil ->
          changes

        v when is_binary(v) ->
          trimmed = v |> String.trim() |> String.downcase()
          if trimmed == "", do: changes, else: Map.put(changes, :email, trimmed)

        _ ->
          changes
      end

    changes =
      case Map.get(normalized, "active") do
        nil ->
          case Map.get(normalized, "is_active") do
            nil -> changes
            v -> put_active(changes, v)
          end

        v ->
          put_active(changes, v)
      end

    case role_id_or_nil do
      :no_change -> changes
      nil -> changes
      id when is_integer(id) -> Map.put(changes, :role_id, id)
    end
  end

  defp put_active(changes, v) when is_boolean(v), do: Map.put(changes, :active, v)

  defp put_active(changes, v) when is_binary(v) do
    case String.downcase(String.trim(v)) do
      "true" -> Map.put(changes, :active, true)
      "false" -> Map.put(changes, :active, false)
      "1" -> Map.put(changes, :active, true)
      "0" -> Map.put(changes, :active, false)
      _ -> changes
    end
  end

  defp put_active(changes, v) when is_integer(v) do
    if v == 0, do: Map.put(changes, :active, false), else: Map.put(changes, :active, true)
  end

  defp put_active(changes, _), do: changes

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
