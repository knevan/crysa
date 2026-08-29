defmodule Crysa.AccountsAdminTest do
  use Crysa.DataCase, async: true

  alias Crysa.Accounts
  alias Crysa.AccountsFixtures

  describe "admin_list_users/1" do
    test "returns paginated users with roles preloaded" do
      _a = AccountsFixtures.user_fixture(%{username: "alice123"})
      _b = AccountsFixtures.user_fixture(%{username: "bob123"})

      {users, pagination} = Accounts.admin_list_users(%{})

      assert pagination.page == 1
      assert pagination.page_size == 25
      assert pagination.total_entries >= 2
      assert length(users) >= 2
      assert Enum.all?(users, & &1.role != nil)
    end

    test "search filters by username and email case-insensitively and escapes wildcards" do
      AccountsFixtures.user_fixture(%{username: "charlie123", email: "charlie@example.com"})
      AccountsFixtures.user_fixture(%{username: "dave123", email: "dave@example.com"})

      {users, _} = Accounts.admin_list_users(%{"q" => "%"})
      assert users == []

      {users, _} = Accounts.admin_list_users(%{"q" => "charlie"})
      assert length(users) == 1
      assert hd(users).username == "charlie123"

      {users, _} = Accounts.admin_list_users(%{"q" => "CHARLIE"})
      assert length(users) == 1
    end

    test "clamps page_size and page" do
      for _ <- 1..3, do: AccountsFixtures.user_fixture()

      {users, pagination} = Accounts.admin_list_users(%{"page_size" => "999"})
      assert pagination.page_size == 100
      assert length(users) <= 100

      {_users, pagination} = Accounts.admin_list_users(%{"page_size" => "0"})
      assert pagination.page_size == 1
    end

    test "returns empty when no match" do
      {users, pagination} = Accounts.admin_list_users(%{"q" => "no-such-user-zzz"})
      assert users == []
      assert pagination.total_entries == 0
    end
  end
end
