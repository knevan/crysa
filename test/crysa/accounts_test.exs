defmodule Crysa.AccountsTest do
  use Crysa.DataCase, async: false

  alias Crysa.Accounts
  alias Crysa.Accounts.{PasswordResetToken, User, UserProfile, UsersToken}
  alias Crysa.AccountsFixtures

  describe "register_user/1" do
    test "registers a user with the default role, hashed password, and profile" do
      {:ok, user} = Accounts.register_user(register_params())

      assert user.role.name == "user"
      assert user.active
      assert user.password_hash != AccountsFixtures.register_password()
      assert Accounts.valid_password?(AccountsFixtures.register_password(), user.password_hash)
      assert %UserProfile{} = Accounts.get_or_create_profile(user)
    end

    test "normalizes email and username" do
      {:ok, user} =
        Accounts.register_user(
          register_params(%{email: "  Admin@Example.COM ", username: "  Admin1  "})
        )

      assert user.email == "admin@example.com"
      assert user.username == "Admin1"
    end

    test "rejects a weak password" do
      {:error, changeset} = Accounts.register_user(register_params(%{password: "short"}))

      refute changeset.valid?
      assert changeset.errors[:password]
    end

    test "rejects a password without a digit" do
      {:error, changeset} =
        Accounts.register_user(register_params(%{password: "onlyletters"}))

      refute changeset.valid?
      assert changeset.errors[:password]
    end

    test "rejects a mismatched confirmation" do
      {:error, changeset} =
        Accounts.register_user(register_params(%{password_confirmation: "password123"}))

      refute changeset.valid?
      assert changeset.errors[:password_confirmation]
    end

    test "rejects an invalid username" do
      {:error, changeset} = Accounts.register_user(register_params(%{username: "bad user!"}))

      refute changeset.valid?
      assert changeset.errors[:username]
    end

    test "rejects a duplicate email case-insensitively" do
      AccountsFixtures.user_fixture(%{email: "dup@example.com"})
      {:error, changeset} = Accounts.register_user(register_params(%{email: "DUP@example.com"}))

      refute changeset.valid?
      assert changeset.errors[:email]
    end

    test "rejects a duplicate username" do
      AccountsFixtures.user_fixture(%{username: "takenname"})
      {:error, changeset} = Accounts.register_user(register_params(%{username: "takenname"}))

      refute changeset.valid?
      assert changeset.errors[:username]
    end
  end

  describe "authenticate_user/2" do
    setup do
      %{user: AccountsFixtures.user_fixture()}
    end

    test "authenticates by email", %{user: user} do
      assert {:ok, authenticated} =
               Accounts.authenticate_user(user.email, AccountsFixtures.password())

      assert authenticated.id == user.id
    end

    test "authenticates by username", %{user: user} do
      assert {:ok, authenticated} =
               Accounts.authenticate_user(user.username, AccountsFixtures.password())

      assert authenticated.id == user.id
    end

    test "rejects a wrong password", %{user: user} do
      assert {:error, :invalid_credentials} =
               Accounts.authenticate_user(user.email, "wrongpassword")
    end

    test "rejects an unknown login" do
      assert {:error, :invalid_credentials} =
               Accounts.authenticate_user("nobody@example.com", AccountsFixtures.password())
    end

    test "rejects an inactive user" do
      user = AccountsFixtures.user_fixture(%{active: false})

      assert {:error, :inactive} =
               Accounts.authenticate_user(user.email, AccountsFixtures.password())
    end

    test "finds users by email case-insensitively" do
      user = AccountsFixtures.user_fixture()

      assert Accounts.get_user_by_email(String.upcase(user.email)).id == user.id
      assert Accounts.get_user_by_email("  #{String.upcase(user.email)}  ").id == user.id
    end
  end

  describe "create_bootstrap_user/1" do
    test "creates a user with the given role and precomputed hash" do
      superadmin = AccountsFixtures.role("superadmin")

      assert {:ok, user} =
               Accounts.create_bootstrap_user(%{
                 email: "boot@example.com",
                 username: "bootadmin",
                 password_hash: AccountsFixtures.password_hash(),
                 role_id: superadmin.id
               })

      assert user.role_id == superadmin.id
      assert user.active
      assert Accounts.valid_password?(AccountsFixtures.password(), user.password_hash)
    end

    test "rejects bootstrap data without a password hash" do
      superadmin = AccountsFixtures.role("superadmin")

      assert {:error, changeset} =
               Accounts.create_bootstrap_user(%{
                 email: "boot@example.com",
                 username: "bootadmin",
                 role_id: superadmin.id
               })

      assert changeset.errors[:password_hash]
    end

    test "rejects bootstrap data without a role" do
      assert {:error, changeset} =
               Accounts.create_bootstrap_user(%{
                 email: "boot@example.com",
                 username: "bootadmin",
                 password_hash: AccountsFixtures.password_hash()
               })

      assert changeset.errors[:role_id]
    end

    test "rejects a duplicate email" do
      existing = AccountsFixtures.user_fixture()
      superadmin = AccountsFixtures.role("superadmin")

      assert {:error, changeset} =
               Accounts.create_bootstrap_user(%{
                 email: String.upcase(existing.email),
                 username: "bootadmin",
                 password_hash: AccountsFixtures.password_hash(),
                 role_id: superadmin.id
               })

      assert changeset.errors[:email]
    end
  end

  describe "session tokens" do
    setup do
      %{user: AccountsFixtures.user_fixture()}
    end

    test "generates and resolves a session token", %{user: user} do
      token = Accounts.generate_user_session_token(user)

      assert %User{id: id} = Accounts.get_user_by_session_token(token)
      assert id == user.id
    end

    test "returns nil for an unknown token" do
      assert Accounts.get_user_by_session_token("unknown") == nil
    end

    test "rejects an expired session token", %{user: user} do
      token = Accounts.generate_user_session_token(user)

      now = DateTime.utc_now()
      past = now |> DateTime.add(-15, :day) |> DateTime.truncate(:second)

      Repo.update_all(
        from(t in UsersToken, where: t.token == ^token),
        set: [inserted_at: past]
      )

      assert Accounts.get_user_by_session_token(token) == nil
    end

    test "deletes a session token", %{user: user} do
      token = Accounts.generate_user_session_token(user)
      Accounts.delete_user_session_token(token)

      assert Accounts.get_user_by_session_token(token) == nil
    end

    test "deletes all sessions for a user", %{user: user} do
      Accounts.generate_user_session_token(user)
      Accounts.generate_user_session_token(user)
      Accounts.delete_all_user_sessions(user)

      assert Repo.all(from(t in UsersToken, where: t.user_id == ^user.id)) == []
    end
  end

  describe "password reset" do
    setup do
      %{user: AccountsFixtures.user_fixture()}
    end

    test "creates a token and resolves it back to the user", %{user: user} do
      {:ok, token} = Accounts.create_reset_token(user)

      assert %User{id: id} = Accounts.get_user_by_reset_password_token(token)
      assert id == user.id
    end

    test "stores a digest, not the raw token", %{user: user} do
      {:ok, token} = Accounts.create_reset_token(user)

      assert Repo.all(from(t in PasswordResetToken, where: t.user_id == ^user.id))
             |> Enum.all?(fn t -> t.token_digest != token end)
    end

    test "returns nil for an unknown token", %{user: _user} do
      assert Accounts.get_user_by_reset_password_token("invalid-token") == nil
    end

    test "returns nil for an expired token", %{user: user} do
      raw = :crypto.strong_rand_bytes(32)
      raw_token = Base.url_encode64(raw, padding: false)
      digest = :crypto.hash(:sha256, raw)

      {:ok, _} =
        Accounts.create_password_reset_token(%{
          user_id: user.id,
          token_digest: digest,
          expires_at: DateTime.utc_now() |> DateTime.add(-1, :hour)
        })

      assert Accounts.get_user_by_reset_password_token(raw_token) == nil
    end

    test "resets the password and marks the token used", %{user: user} do
      {:ok, token} = Accounts.create_reset_token(user)

      assert {:ok, updated} =
               Accounts.reset_user_password(
                 user,
                 %{
                   password: "newpassword456",
                   password_confirmation: "newpassword456"
                 },
                 token
               )

      assert Accounts.valid_password?("newpassword456", updated.password_hash)
      refute Accounts.valid_password?(AccountsFixtures.password(), updated.password_hash)
      assert Accounts.get_user_by_reset_password_token(token) == nil
    end

    test "reset invalidates existing sessions", %{user: user} do
      Accounts.generate_user_session_token(user)
      {:ok, token} = Accounts.create_reset_token(user)

      {:ok, _} =
        Accounts.reset_user_password(
          user,
          %{
            password: "newpassword456",
            password_confirmation: "newpassword456"
          },
          token
        )

      assert Repo.all(from(t in UsersToken, where: t.user_id == ^user.id)) == []
    end

    test "rejects an unknown token", %{user: user} do
      assert {:error, :invalid_token} =
               Accounts.reset_user_password(
                 user,
                 %{password: "newpassword456", password_confirmation: "newpassword456"},
                 "invalid-token"
               )
    end

    test "rejects a token belonging to another user" do
      user_a = AccountsFixtures.user_fixture()
      user_b = AccountsFixtures.user_fixture()
      {:ok, token} = Accounts.create_reset_token(user_a)

      assert {:error, :invalid_token} =
               Accounts.reset_user_password(
                 user_b,
                 %{password: "newpassword456", password_confirmation: "newpassword456"},
                 token
               )
    end

    test "rejects an expired token", %{user: user} do
      raw = :crypto.strong_rand_bytes(32)
      token = Base.url_encode64(raw, padding: false)

      Accounts.create_password_reset_token(%{
        user_id: user.id,
        token_digest: :crypto.hash(:sha256, raw),
        expires_at: DateTime.utc_now() |> DateTime.add(-1, :hour)
      })

      assert {:error, :invalid_token} =
               Accounts.reset_user_password(
                 user,
                 %{password: "newpassword456", password_confirmation: "newpassword456"},
                 token
               )
    end
  end

  describe "update_user_password/2" do
    setup do
      %{user: AccountsFixtures.user_fixture()}
    end

    test "requires the current password", %{user: user} do
      assert {:error, changeset} =
               Accounts.update_user_password(user, %{
                 password: "newpassword456",
                 password_confirmation: "newpassword456"
               })

      assert changeset.errors[:current_password]
    end

    test "rejects a wrong current password", %{user: user} do
      assert {:error, changeset} =
               Accounts.update_user_password(user, %{
                 current_password: "wrongpassword",
                 password: "newpassword456",
                 password_confirmation: "newpassword456"
               })

      assert changeset.errors[:current_password]
    end

    test "updates the password with a valid current password", %{user: user} do
      assert {:ok, updated} =
               Accounts.update_user_password(user, %{
                 current_password: AccountsFixtures.password(),
                 password: "newpassword456",
                 password_confirmation: "newpassword456"
               })

      assert Accounts.valid_password?("newpassword456", updated.password_hash)
    end

    test "invalidates other sessions while keeping the caller's", %{user: user} do
      keep = Accounts.generate_user_session_token(user)
      other = Accounts.generate_user_session_token(user)

      assert {:ok, _updated} =
               Accounts.update_user_password(
                 user,
                 %{
                   current_password: AccountsFixtures.password(),
                   password: "newpassword456",
                   password_confirmation: "newpassword456"
                 },
                 keep_session: keep
               )

      assert Accounts.get_user_by_session_token(keep) != nil
      assert Accounts.get_user_by_session_token(other) == nil
    end
  end

  describe "cleanup_expired_tokens/0" do
    test "deletes expired sessions and reset tokens" do
      user = AccountsFixtures.user_fixture()
      token = Accounts.generate_user_session_token(user)

      past = DateTime.utc_now() |> DateTime.add(-15, :day) |> DateTime.truncate(:second)

      Repo.update_all(
        from(t in UsersToken, where: t.token == ^token),
        set: [inserted_at: past]
      )

      raw = :crypto.strong_rand_bytes(32)
      digest = :crypto.hash(:sha256, raw)

      Accounts.create_password_reset_token(%{
        user_id: user.id,
        token_digest: digest,
        expires_at: DateTime.utc_now() |> DateTime.add(-1, :hour)
      })

      assert Accounts.cleanup_expired_tokens() == 2
    end
  end

  describe "profiles" do
    setup do
      %{user: AccountsFixtures.user_fixture()}
    end

    test "updates the display name", %{user: user} do
      assert {:ok, profile} = Accounts.update_profile(user, %{display_name: "Reader One"})
      assert profile.display_name == "Reader One"
    end
  end

  defp register_params(attrs \\ %{}) do
    Map.merge(
      %{
        email: AccountsFixtures.unique_email(),
        username: AccountsFixtures.unique_username(),
        password: AccountsFixtures.register_password(),
        password_confirmation: AccountsFixtures.register_password()
      },
      attrs
    )
  end
end
