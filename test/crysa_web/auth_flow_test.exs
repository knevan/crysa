defmodule CrysaWeb.AuthFlowTest do
  use CrysaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Swoosh.TestAssertions

  alias Crysa.Accounts
  alias Crysa.AccountsFixtures

  setup %{conn: conn} do
    %{conn: conn}
  end

  describe "registration" do
    test "renders the registration page", %{conn: conn} do
      conn = get(conn, ~p"/users/register")
      assert html_response(conn, 200) =~ "Create your account"
    end

    test "creates an account and logs in", %{conn: conn} do
      params = %{
        email: "new@example.com",
        username: "newuser",
        password: "password1234",
        password_confirmation: "password1234"
      }

      conn = post(conn, ~p"/users/register", user: params)

      assert redirected_to(conn) == ~p"/users/settings"
      assert get_session(conn, :user_token)

      user = Accounts.get_user_by_email("new@example.com")
      assert user.role.name == "user"
    end

    test "rejects invalid registration and redirects back", %{conn: conn} do
      params = %{
        email: "bad",
        username: "x",
        password: "short",
        password_confirmation: "short"
      }

      conn = post(conn, ~p"/users/register", user: params)

      assert redirected_to(conn) == ~p"/users/register"
      assert Phoenix.Flash.get(conn.assigns.flash, :error)
      refute get_session(conn, :user_token)
    end
  end

  describe "login and logout" do
    setup %{conn: conn} do
      %{user: AccountsFixtures.user_fixture(), conn: conn}
    end

    test "logs in with an email", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/users/log-in", %{
          user: %{login: user.email, password: AccountsFixtures.password()}
        })

      assert redirected_to(conn) == ~p"/users/settings"
      assert get_session(conn, :user_token)
    end

    test "logs in with a username", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/users/log-in", %{
          user: %{login: user.username, password: AccountsFixtures.password()}
        })

      assert redirected_to(conn) == ~p"/users/settings"
      assert get_session(conn, :user_token)
    end

    test "rejects a wrong password", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/users/log-in", %{
          user: %{login: user.email, password: "wrongpassword"}
        })

      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Invalid"
    end

    test "rejects an inactive user", %{conn: conn} do
      inactive = AccountsFixtures.user_fixture(%{active: false})

      conn =
        post(conn, ~p"/users/log-in", %{
          user: %{login: inactive.email, password: AccountsFixtures.password()}
        })

      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "disabled"
    end

    test "logs out and clears the session", %{conn: conn, user: user} do
      token = Accounts.generate_user_session_token(user)

      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> put_session(:user_token, token)
        |> delete(~p"/users/log-out")

      assert redirected_to(conn) == ~p"/"
      assert get_session(conn, :user_token) == nil
      assert Accounts.get_user_by_session_token(token) == nil
    end
  end

  describe "protected pages" do
    test "redirects unauthenticated users away from settings", %{conn: conn} do
      conn = get(conn, ~p"/users/settings")
      assert redirected_to(conn) == ~p"/users/log-in"
    end

    test "renders settings for an authenticated user", %{conn: conn} do
      conn = conn |> log_in() |> get(~p"/users/settings")
      assert html_response(conn, 200) =~ "Account settings"
    end

    test "renders profile for an authenticated user", %{conn: conn} do
      conn = conn |> log_in() |> get(~p"/users/profile")
      assert html_response(conn, 200) =~ "Your profile"
    end
  end

  describe "role guards" do
    setup %{conn: conn} do
      %{conn: conn}
    end

    test "denies regular users from the admin area", %{conn: conn} do
      user = AccountsFixtures.user_fixture()
      conn = conn |> log_in(user) |> get(~p"/admin")

      assert response(conn, 403)
    end

    test "allows admins into the admin area", %{conn: conn} do
      admin = AccountsFixtures.user_fixture(%{role_name: "admin"})
      conn = conn |> log_in(admin) |> get(~p"/admin")

      assert html_response(conn, 200) =~ "Admin dashboard"
    end

    test "denies regular users from the moderator area", %{conn: conn} do
      user = AccountsFixtures.user_fixture()
      conn = conn |> log_in(user) |> get(~p"/moderator")

      assert response(conn, 403)
    end

    test "allows moderators into the moderator area", %{conn: conn} do
      moderator = AccountsFixtures.user_fixture(%{role_name: "moderator"})
      conn = conn |> log_in(moderator) |> get(~p"/moderator")

      assert html_response(conn, 200) =~ "Moderator dashboard"
    end

    test "denies moderators from the admin area", %{conn: conn} do
      moderator = AccountsFixtures.user_fixture(%{role_name: "moderator"})
      conn = conn |> log_in(moderator) |> get(~p"/admin")

      assert response(conn, 403)
    end
  end

  describe "forgot and reset password" do
    setup %{conn: conn} do
      %{conn: conn}
    end

    test "sends reset instructions for a known email", %{conn: conn} do
      user = AccountsFixtures.user_fixture()

      conn =
        post(conn, ~p"/users/reset_password", %{
          user: %{email: user.email}
        })

      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "If your email is in our system"

      assert_email_sent(fn email ->
        assert email.to == [{"", user.email}]
        assert email.subject == "Reset your password"
      end)
    end

    test "does not leak whether an email exists", %{conn: conn} do
      conn =
        post(conn, ~p"/users/reset_password", %{
          user: %{email: "nobody@example.com"}
        })

      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "If your email is in our system"
    end

    test "resets the password end to end", %{conn: conn} do
      user = AccountsFixtures.user_fixture()
      {:ok, token} = Accounts.create_reset_token(user)

      conn =
        post(conn, ~p"/users/reset_password/#{token}", %{
          user: %{password: "brandnewpassword9", password_confirmation: "brandnewpassword9"}
        })

      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "password has been reset"

      assert {:ok, authenticated} =
               Accounts.authenticate_user(user.email, "brandnewpassword9")

      assert authenticated.id == user.id
      assert Accounts.get_user_by_reset_password_token(token) == nil
    end

    test "rejects an expired token", %{conn: conn} do
      user = AccountsFixtures.user_fixture()
      raw = :crypto.strong_rand_bytes(32)
      token = Base.url_encode64(raw, padding: false)

      Accounts.create_password_reset_token(%{
        user_id: user.id,
        token_digest: :crypto.hash(:sha256, raw),
        expires_at: DateTime.utc_now() |> DateTime.add(-1, :hour)
      })

      conn =
        post(conn, ~p"/users/reset_password/#{token}", %{
          user: %{password: "brandnewpassword9", password_confirmation: "brandnewpassword9"}
        })

      assert redirected_to(conn) == ~p"/users/reset_password"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "invalid or has expired"

      assert {:error, :invalid_credentials} =
               Accounts.authenticate_user(user.email, "brandnewpassword9")
    end

    test "renders the invalid token page", %{conn: conn} do
      conn = get(conn, ~p"/users/reset_password/invalid-token")
      assert html_response(conn, 200) =~ "Reset link invalid or expired"
    end
  end

  describe "password change" do
    test "changes the password from the settings page", %{conn: conn} do
      user = AccountsFixtures.user_fixture()

      conn = conn |> log_in(user) |> get(~p"/users/settings")
      assert html_response(conn, 200) =~ "Account settings"

      {:ok, view, html} = live(conn, ~p"/users/settings")
      assert html =~ "Account settings"

      view
      |> form("#password_form", user: %{})
      |> render_submit(%{
        user: %{
          current_password: AccountsFixtures.password(),
          password: "newpassword456",
          password_confirmation: "newpassword456"
        }
      })

      assert Accounts.valid_password?("newpassword456", Accounts.get_user!(user.id).password_hash)
    end

    test "rejects a wrong current password", %{conn: conn} do
      user = AccountsFixtures.user_fixture()

      {:ok, view, _html} = conn |> log_in(user) |> live(~p"/users/settings")

      html =
        view
        |> form("#password_form", user: %{})
        |> render_submit(%{
          user: %{
            current_password: "wrongpassword",
            password: "newpassword456",
            password_confirmation: "newpassword456"
          }
        })

      assert html =~ "is incorrect"
    end
  end

  describe "avatar upload" do
    test "uploads an avatar", %{conn: conn} do
      user = AccountsFixtures.user_fixture()
      path = Path.join(System.tmp_dir!(), "avatar-#{System.unique_integer([:positive])}.png")
      File.write!(path, "fake-image-bytes")

      upload = %Plug.Upload{path: path, content_type: "image/png", filename: "avatar.png"}

      conn =
        conn
        |> log_in(user)
        |> post(~p"/users/profile/avatar", %{avatar: upload})

      File.rm(path)

      assert redirected_to(conn) == ~p"/users/profile"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Avatar updated"

      profile = Accounts.get_or_create_profile(user)
      assert profile.avatar_url =~ ~r{^/uploads/avatars/}
    end

    test "rejects a non-image content type", %{conn: conn} do
      user = AccountsFixtures.user_fixture()
      path = Path.join(System.tmp_dir!(), "avatar-#{System.unique_integer([:positive])}.txt")
      File.write!(path, "not an image")

      upload = %Plug.Upload{path: path, content_type: "text/plain", filename: "a.txt"}

      conn =
        conn
        |> log_in(user)
        |> post(~p"/users/profile/avatar", %{avatar: upload})

      File.rm(path)

      assert redirected_to(conn) == ~p"/users/profile"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Only JPEG"
    end

    test "requires authentication", %{conn: conn} do
      conn = post(conn, ~p"/users/profile/avatar")
      assert redirected_to(conn) == ~p"/users/log-in"
    end
  end

  defp log_in(conn, user \\ nil) do
    user = user || AccountsFixtures.user_fixture()
    token = Accounts.generate_user_session_token(user)
    conn |> Plug.Test.init_test_session(%{}) |> put_session(:user_token, token)
  end
end
