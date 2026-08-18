defmodule CrysaWeb.UserAuthTest do
  use CrysaWeb.ConnCase, async: false

  alias Crysa.Accounts
  alias Crysa.Accounts.UsersToken
  alias Crysa.AccountsFixtures
  alias Crysa.Repo
  alias CrysaWeb.UserAuth

  import Ecto.Query

  setup %{conn: conn} do
    %{
      user: AccountsFixtures.user_fixture(),
      conn: conn |> Plug.Test.init_test_session(%{}) |> fetch_flash()
    }
  end

  describe "log_in_user/2" do
    test "stores a session token and redirects", %{conn: conn, user: user} do
      conn = UserAuth.log_in_user(conn, user)

      assert redirected_to(conn) == ~p"/users/settings"
      assert get_session(conn, :user_token)
      assert get_session(conn, :live_socket_id)
      assert Repo.one(from t in UsersToken, where: t.user_id == ^user.id)
    end

    test "redirects to the stored return_to path when present", %{conn: conn, user: user} do
      conn = put_session(conn, :user_return_to, "/series/123")
      conn = UserAuth.log_in_user(conn, user)

      assert redirected_to(conn) == "/series/123"
    end
  end

  describe "log_out_user/1" do
    test "clears the session and deletes the token", %{conn: conn, user: user} do
      token = Accounts.generate_user_session_token(user)
      conn = conn |> put_session(:user_token, token) |> UserAuth.log_out_user()

      assert redirected_to(conn) == ~p"/"
      assert get_session(conn, :user_token) == nil
      assert Accounts.get_user_by_session_token(token) == nil
    end
  end

  describe "fetch_current_user/2" do
    test "assigns the user when the session token is valid", %{conn: conn, user: user} do
      token = Accounts.generate_user_session_token(user)
      conn = put_session(conn, :user_token, token)

      conn = UserAuth.fetch_current_user(conn, [])

      assert conn.assigns.current_user.id == user.id
      assert conn.assigns.current_user.role.name == "user"
    end

    test "assigns nil without a session token", %{conn: conn} do
      conn = UserAuth.fetch_current_user(conn, [])
      assert conn.assigns.current_user == nil
    end

    test "assigns nil for an invalid token", %{conn: conn} do
      conn = conn |> put_session(:user_token, "invalid") |> UserAuth.fetch_current_user([])
      assert conn.assigns.current_user == nil
    end
  end

  describe "require_authenticated_user/2" do
    test "halts and redirects when not authenticated", %{conn: conn} do
      conn = UserAuth.require_authenticated_user(conn, [])

      assert conn.halted
      assert redirected_to(conn) == ~p"/users/log-in"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "You must log in to access this page."
    end

    test "passes through when authenticated", %{conn: conn, user: user} do
      conn = conn |> assign(:current_user, user) |> UserAuth.require_authenticated_user([])

      refute conn.halted
    end
  end

  describe "require_role/2" do
    test "returns 403 for an insufficient role", %{conn: conn, user: user} do
      conn = conn |> assign(:current_user, user) |> UserAuth.require_role(["admin"])

      assert conn.status == 403
      assert conn.halted
    end

    test "passes through for a sufficient role", %{conn: conn, user: user} do
      conn = conn |> assign(:current_user, user) |> UserAuth.require_role(["user"])

      refute conn.halted
    end

    test "returns 403 without a current user", %{conn: conn} do
      conn = UserAuth.require_role(conn, ["user"])

      assert conn.status == 403
      assert conn.halted
    end
  end

  describe "require_admin/2" do
    test "allows an admin user", %{conn: conn} do
      admin = AccountsFixtures.user_fixture(%{role_name: "admin"})
      conn = conn |> assign(:current_user, admin) |> UserAuth.require_admin([])

      refute conn.halted
    end

    test "denies a moderator", %{conn: conn} do
      moderator = AccountsFixtures.user_fixture(%{role_name: "moderator"})
      conn = conn |> assign(:current_user, moderator) |> UserAuth.require_admin([])

      assert conn.status == 403
      assert conn.halted
    end
  end

  describe "require_moderator/2" do
    test "allows a moderator", %{conn: conn} do
      moderator = AccountsFixtures.user_fixture(%{role_name: "moderator"})
      conn = conn |> assign(:current_user, moderator) |> UserAuth.require_moderator([])

      refute conn.halted
    end

    test "denies a regular user", %{conn: conn, user: user} do
      conn = conn |> assign(:current_user, user) |> UserAuth.require_moderator([])

      assert conn.status == 403
      assert conn.halted
    end
  end
end
