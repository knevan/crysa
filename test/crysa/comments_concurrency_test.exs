defmodule Crysa.CommentsConcurrencyTest do
  @moduledoc """
  Concurrency test for comment votes – ensures vote_score stays consistent
  under concurrent writers (same pattern as LibraryConcurrencyTest).
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias Crysa.Accounts.User
  alias Crysa.AccountsFixtures
  alias Crysa.CatalogFixtures
  alias Crysa.Comments
  alias Crysa.Repo

  @timeout 30_000

  setup_all do
    unboxed(fn -> Enum.each(~w(superadmin admin moderator user), &AccountsFixtures.role/1) end)
    :ok
  end

  test "concurrent upvotes from many users keep vote_score consistent" do
    unboxed(fn ->
      {comment, users, author, series} = seed_comment_with_users(5)
      register_cleanup(comment, users, author, series)

      results =
        users
        |> Task.async_stream(fn user -> Comments.vote_comment(user, comment, 1) end,
          max_concurrency: 5,
          timeout: @timeout,
          ordered: false
        )
        |> Enum.map(fn {:ok, res} -> res end)

      assert Enum.all?(results, &match?({:ok, _}, &1))
      assert %{vote_score: 5} = Repo.get!(Crysa.Comments.Comment, comment.id)
    end)
  end

  test "concurrent vote flips by one user keep single row and correct score" do
    unboxed(fn ->
      {comment, [user | _], author, series} = seed_comment_with_users(1)
      register_cleanup(comment, [user], author, series)

      # start with no vote
      votes = [1, -1, 1, -1, 1]

      results =
        votes
        |> Task.async_stream(fn v -> Comments.vote_comment(user, comment, v) end,
          max_concurrency: 5,
          timeout: @timeout,
          ordered: false
        )
        |> Enum.map(fn {:ok, res} -> res end)

      assert Enum.all?(results, &match?({:ok, _}, &1))
      # Only one vote row should exist
      assert Repo.aggregate(
               from(v in Crysa.Comments.Vote, where: v.comment_id == ^comment.id),
               :count,
               :user_id
             ) == 1

      # Score must be -1, 1 (one of the values) and match the stored vote
      vote =
        Repo.one!(
          from(v in Crysa.Comments.Vote,
            where: v.user_id == ^user.id and v.comment_id == ^comment.id
          )
        )

      assert %{vote_score: score} = Repo.get!(Crysa.Comments.Comment, comment.id)
      assert score == vote.vote
      assert score in [-1, 1]
    end)
  end

  defp unboxed(fun), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fun)

  defp seed_comment_with_users(count) do
    author = AccountsFixtures.user_fixture()
    series = CatalogFixtures.series_fixture()

    {:ok, comment} =
      Comments.create_comment(%{
        user_id: author.id,
        series_id: series.id,
        body_markdown: "concurrency"
      })

    users = for _ <- 1..count, do: AccountsFixtures.user_fixture()
    {comment, users, author, series}
  end

  defp register_cleanup(comment, users, author, series) do
    on_exit(fn -> cleanup_unboxed(comment, users, author, series) end)
  end

  defp cleanup_unboxed(comment, users, author, series) do
    unboxed(fn ->
      if users != [] do
        Repo.delete_all(from(u in User, where: u.id in ^Enum.map(users, & &1.id)))
      end

      Repo.delete_all(from(c in Crysa.Comments.Comment, where: c.id == ^comment.id))
      Repo.delete_all(from(u in User, where: u.id == ^author.id))
      Repo.delete_all(from(s in Crysa.Catalog.Series, where: s.id == ^series.id))
    end)
  end
end
