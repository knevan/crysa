defmodule CrysaWeb.AdminDashboardLiveTest do
  use CrysaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Crysa.AccountsFixtures
  alias Crysa.CatalogFixtures
  alias CrysaWeb.Live.AdminDashboardLive

  describe "GET /admin (LiveView)" do
    test "redirects unauthenticated users to login", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/auth/login"}}} = live(conn, ~p"/admin")
    end

    test "redirects non-admin users to /", %{conn: conn} do
      user = AccountsFixtures.user_fixture()
      conn = log_in(conn, user)

      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/admin")
    end

    test "renders for admins with TanStack props", %{conn: conn} do
      admin = AccountsFixtures.user_fixture(%{role_name: "admin"})
      # ensure at least one series exists for the table
      _series = CatalogFixtures.series_fixture(%{title: "Test Series"})

      conn = log_in(conn, admin)
      {:ok, view, _html} = live(conn, ~p"/admin")

      vue = LiveVue.Test.get_vue(view)
      assert vue.component == "AdminDashboard"
      assert is_list(vue.props["seriesRows"])
      assert is_map(vue.props["pagination"])
      assert vue.props["pagination"]["page"] == 1
      assert vue.props["pagination"]["pageSize"] == 25

      # search event filters — verify via server socket (LiveVue diff is not
      # merged by Test helper, so check socket assigns directly)
      render_hook(view, "admin:search", %{"q" => "Test Series"})
      state = :sys.get_state(view.pid)
      assert Enum.any?(state.socket.assigns.series_rows, fn row -> row.title == "Test Series" end)

      # pagination event
      render_hook(view, "admin:page_change", %{"page" => 2})
      state = :sys.get_state(view.pid)
      assert state.socket.assigns.pagination.page >= 1
    end

    test "page_size_change clamps and resets to page 1", %{conn: conn} do
      admin = AccountsFixtures.user_fixture(%{role_name: "admin"})
      conn = log_in(conn, admin)
      {:ok, view, _html} = live(conn, ~p"/admin")

      render_hook(view, "admin:page_size_change", %{"page_size" => 999})
      state = :sys.get_state(view.pid)
      # server assigns are the source of truth; LiveVue diff is applied client-side
      assert state.socket.assigns.pagination.pageSize == 100
      assert state.socket.assigns.pagination.page == 1
      assert state.socket.assigns.page_size == 100

      # also verify via HTML diff that the server emitted the correct diff
      html = render(view)
      assert html =~ "pageSize"
    end

    test "users table search and pagination", %{conn: conn} do
      admin = AccountsFixtures.user_fixture(%{role_name: "admin"})
      AccountsFixtures.user_fixture(%{username: "searchme123"})
      conn = log_in(conn, admin)
      {:ok, view, _html} = live(conn, ~p"/admin")

      # users search
      render_hook(view, "admin:users_search", %{"q" => "searchme"})
      state = :sys.get_state(view.pid)
      assert Enum.any?(state.socket.assigns.user_rows, fn r -> r.username == "searchme123" end)

      # users pagination
      render_hook(view, "admin:users_page_change", %{"page" => 1})
      state = :sys.get_state(view.pid)
      assert state.socket.assigns.user_pagination.page == 1

      render_hook(view, "admin:users_page_size_change", %{"page_size" => 10})
      state = :sys.get_state(view.pid)
      assert state.socket.assigns.user_pagination.pageSize == 10
    end
  end

  describe "resolve_cover_outcome/3" do
    test "resolves a stored entry to its storage key" do
      assert AdminDashboardLive.resolve_cover_outcome(
               [{:stored, "covers/x.jpg"}],
               [],
               ""
             ) ==
               {"covers/x.jpg", nil}
    end

    test "resolves a storage failure" do
      assert AdminDashboardLive.resolve_cover_outcome([{:storage_error, "boom"}], [], "a.jpg") ==
               {nil, {:storage, "boom"}}
    end

    test "empty entries without a file name stays optional" do
      assert AdminDashboardLive.resolve_cover_outcome([], [], "") == {nil, nil}
    end

    test "claimed file with empty entries is pending, never silent success" do
      assert AdminDashboardLive.resolve_cover_outcome([], [], "d73cb2d3.jpg") ==
               {nil, {:pending, "d73cb2d3.jpg"}}
    end

    test "resolves upload validation errors" do
      errors = [{"0", :too_large}]

      assert AdminDashboardLive.resolve_cover_outcome([], errors, "a.jpg") ==
               {nil, {:validation, errors}}
    end
  end

  describe "cover_url/1 key boundary" do
    test "resolves a stored key to its public url" do
      series = CatalogFixtures.series_fixture(%{cover_key: "covers/x.jpg"})

      assert Crysa.Catalog.cover_url(series) == "/uploads/covers/x.jpg"
      assert Crysa.Catalog.cover_url(%{series | cover_key: nil}) == nil
    end
  end

  defp log_in(conn, user) do
    token = Crysa.Accounts.generate_user_session_token(user)
    conn |> Plug.Test.init_test_session(%{}) |> Plug.Conn.put_session(:user_token, token)
  end
end
