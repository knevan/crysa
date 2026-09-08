defmodule Crysa.NotificationsTest do
  @moduledoc false

  use Crysa.DataCase, async: false

  import Crysa.CatalogFixtures

  alias Crysa.AccountsFixtures
  alias Crysa.Comments
  alias Crysa.Library
  alias Crysa.Notifications
  alias Crysa.Notifications.Notification
  alias Crysa.Repo

  setup do
    author = AccountsFixtures.user_fixture()
    voter = AccountsFixtures.user_fixture()
    series = series_fixture()
    chapter = chapter_fixture(series)

    {:ok, comment} =
      Comments.create_comment(%{
        user_id: author.id,
        series_id: series.id,
        body_markdown: "parent comment"
      })

    %{author: author, voter: voter, series: series, chapter: chapter, comment: comment}
  end

  describe "actions/0" do
    test "covers comment activity and series updates" do
      assert Notifications.actions() == [
               "comment_reply",
               "comment_upvote",
               "comment_downvote",
               "series_chapter"
             ]

      assert Notifications.tabs() == ["comment", "series"]
    end
  end

  describe "create_notification/1 target integrity" do
    test "rejects comment action without a comment", %{author: author} do
      assert {:error, changeset} =
               Notifications.create_notification(%{
                 recipient_id: author.id,
                 action: "comment_reply"
               })

      assert changeset.errors[:comment_id]
    end

    test "rejects series action without series and chapter", %{author: author} do
      assert {:error, changeset} =
               Notifications.create_notification(%{
                 recipient_id: author.id,
                 action: "series_chapter"
               })

      assert changeset.errors[:comment_id] || changeset.errors[:series_id]
    end

    test "rejects unknown actions", %{author: author, comment: comment} do
      assert {:error, changeset} =
               Notifications.create_notification(%{
                 recipient_id: author.id,
                 comment_id: comment.id,
                 action: "bogus"
               })

      assert changeset.errors[:action]
    end
  end

  describe "vote notifications" do
    test "upvote notifies the comment author", %{author: author, voter: voter, comment: comment} do
      assert {:ok, _} = Comments.vote_comment(voter, comment, 1)

      assert [%Notification{action: "comment_upvote", recipient_id: recipient_id}] =
               Repo.all(Notification)

      assert recipient_id == author.id
    end

    test "downvote notifies the comment author", %{voter: voter, comment: comment} do
      assert {:ok, _} = Comments.vote_comment(voter, comment, -1)

      assert [%Notification{action: "comment_downvote"}] = Repo.all(Notification)
    end

    test "repeating the same vote stays silent", %{voter: voter, comment: comment} do
      assert {:ok, _} = Comments.vote_comment(voter, comment, 1)
      assert {:ok, _} = Comments.vote_comment(voter, comment, 1)

      assert [_one] = Repo.all(Notification)
    end

    test "changing vote direction notifies again", %{voter: voter, comment: comment} do
      assert {:ok, _} = Comments.vote_comment(voter, comment, 1)
      assert {:ok, _} = Comments.vote_comment(voter, comment, -1)

      assert ["comment_downvote", "comment_upvote"] =
               Notification |> Repo.all() |> Enum.map(& &1.action) |> Enum.sort()
    end

    test "unvote then re-vote notifies again", %{voter: voter, comment: comment} do
      assert {:ok, _} = Comments.vote_comment(voter, comment, 1)
      assert :ok = Comments.unvote_comment(voter, comment)
      assert {:ok, _} = Comments.vote_comment(voter, comment, -1)

      assert 2 = Repo.aggregate(Notification, :count, :id)
    end

    test "self-vote never notifies", %{author: author, comment: comment} do
      assert {:ok, _} = Comments.vote_comment(author, comment, 1)
      assert {:ok, _} = Comments.vote_comment(author, comment, -1)

      assert [] = Repo.all(Notification)
    end
  end

  describe "reply notifications" do
    test "reply notifies the parent author", %{
      author: author,
      voter: voter,
      series: series,
      comment: comment
    } do
      assert {:ok, _} =
               Comments.create_comment(%{
                 user_id: voter.id,
                 series_id: series.id,
                 parent_id: comment.id,
                 body_markdown: "reply"
               })

      assert [%Notification{action: "comment_reply", recipient_id: recipient_id}] =
               Repo.all(Notification)

      assert recipient_id == author.id
    end
  end

  describe "series fan-out" do
    test "notifies every bookmarker exactly once per chapter", %{
      series: series,
      chapter: chapter
    } do
      follower_a = AccountsFixtures.user_fixture()
      follower_b = AccountsFixtures.user_fixture()
      outsider = AccountsFixtures.user_fixture()

      assert {:ok, _} = Library.bookmark_series(follower_a, series)
      assert {:ok, _} = Library.bookmark_series(follower_b, series)

      assert {:ok, 2} = Notifications.notify_series_chapter(series.id, chapter.id)

      recipients =
        Notification |> Repo.all() |> Enum.map(& &1.recipient_id) |> Enum.sort()

      assert recipients == Enum.sort([follower_a.id, follower_b.id])
      refute outsider.id in recipients
    end

    test "retries are idempotent", %{series: series, chapter: chapter} do
      follower = AccountsFixtures.user_fixture()
      assert {:ok, _} = Library.bookmark_series(follower, series)

      assert {:ok, 1} = Notifications.notify_series_chapter(series.id, chapter.id)
      assert {:ok, 0} = Notifications.notify_series_chapter(series.id, chapter.id)

      assert 1 = Repo.aggregate(Notification, :count, :id)
    end

    test "no followers means no rows", %{series: series, chapter: chapter} do
      assert {:ok, 0} = Notifications.notify_series_chapter(series.id, chapter.id)
    end
  end

  describe "panel read model" do
    setup %{author: author, voter: voter, series: series, chapter: chapter, comment: comment} do
      {:ok, _} = Comments.vote_comment(voter, comment, 1)
      {:ok, _} = Library.bookmark_series(voter, series)
      {:ok, _} = Notifications.notify_series_chapter(series.id, chapter.id)
      %{author: author}
    end

    test "lists newest first per tab", %{author: author} do
      assert {:ok, {comment_items, false}} =
               Notifications.list_notifications(author.id, "comment")

      assert [%{action: "comment_upvote"}] = comment_items

      assert {:ok, {[], false}} = Notifications.list_notifications(author.id, "series")
    end

    test "unread_only excludes read rows", %{author: author} do
      assert {:ok, {[_one], false}} = Notifications.list_notifications(author.id, "comment")

      assert {:ok, {[_one], false}} =
               Notifications.list_notifications(author.id, "comment", unread_only: false)

      assert {:ok, 1} = Notifications.mark_as_read(author.id, %{scope: "tab", tab: "comment"})

      assert {:ok, {[_one], false}} = Notifications.list_notifications(author.id, "comment")

      assert {:ok, {[], false}} =
               Notifications.list_notifications(author.id, "comment", unread_only: true)
    end

    test "keyset pagination pages older entries", %{author: author, voter: voter, series: series} do
      for n <- 1..3 do
        {:ok, root} =
          Comments.create_comment(%{
            user_id: author.id,
            series_id: series.id,
            body_markdown: "root #{n}"
          })

        {:ok, _} =
          Comments.create_comment(%{
            user_id: voter.id,
            series_id: series.id,
            parent_id: root.id,
            body_markdown: "reply #{n}"
          })
      end

      assert {:ok, {page1, true}} =
               Notifications.list_notifications(author.id, "comment", limit: 2)

      assert [_first, _second] = page1

      cursor = page1 |> List.last() |> Map.fetch!(:id)

      assert {:ok, {page2, _}} =
               Notifications.list_notifications(author.id, "comment", limit: 2, cursor: cursor)

      assert page2 != []
      assert Enum.all?(page2, &(&1.id < cursor))
    end

    test "offset pages numbered windows", %{author: author, voter: voter, series: series} do
      for n <- 1..3 do
        {:ok, root} =
          Comments.create_comment(%{
            user_id: author.id,
            series_id: series.id,
            body_markdown: "root #{n}"
          })

        {:ok, _} =
          Comments.create_comment(%{
            user_id: voter.id,
            series_id: series.id,
            parent_id: root.id,
            body_markdown: "reply #{n}"
          })
      end

      assert {:ok, {page1, true}} =
               Notifications.list_notifications(author.id, "comment", limit: 2)

      assert {:ok, {page2, _}} =
               Notifications.list_notifications(author.id, "comment", limit: 2, offset: 2)

      assert length(page1) == 2
      assert page2 != []

      assert Enum.all?(page2, fn item ->
               Enum.all?(page1, &(&1.id != item.id)) and
                 item.id < Enum.min_by(page1, & &1.id).id
             end)

      assert {:ok, {page1_again, _}} =
               Notifications.list_notifications(author.id, "comment", limit: 2, offset: -5)

      assert Enum.map(page1_again, & &1.id) == Enum.map(page1, & &1.id)
    end

    test "count_notifications totals one tab", %{author: author} do
      assert 1 = Notifications.count_notifications(author.id, "comment")
      assert 0 = Notifications.count_notifications(author.id, "series")
      assert {:error, :invalid_tab} = Notifications.count_notifications(author.id, "bogus")

      assert {:ok, 1} = Notifications.mark_as_read(author.id, %{scope: "tab", tab: "comment"})
      assert 1 = Notifications.count_notifications(author.id, "comment")

      assert 0 =
               Notifications.count_notifications(author.id, "comment", unread_only: true)
    end

    test "unread counts split per tab", %{author: author, voter: voter} do
      assert %{comment: 1, series: 0} = Notifications.unread_counts(author.id)
      assert %{comment: 0, series: 1} = Notifications.unread_counts(voter.id)
      assert 1 = Notifications.unread_count(author.id)
    end

    test "mark as read per item then per tab", %{author: author} do
      assert {:ok, {[item], false}} = Notifications.list_notifications(author.id, "comment")

      assert {:ok, 1} = Notifications.mark_as_read(author.id, %{scope: "item", id: item.id})
      assert %{comment: 0} = Notifications.unread_counts(author.id)

      assert {:error, :not_found} =
               Notifications.mark_as_read(author.id, %{scope: "item", id: item.id})

      assert {:ok, 0} = Notifications.mark_as_read(author.id, %{scope: "tab", tab: "comment"})
    end

    test "mark as read never touches other recipients", %{author: author, voter: voter} do
      assert {:error, :not_found} =
               Notifications.mark_as_read(voter.id, %{scope: "item", id: -1})

      assert {:ok, {[%{id: id}], _}} = Notifications.list_notifications(author.id, "comment")

      assert {:error, :not_found} =
               Notifications.mark_as_read(voter.id, %{scope: "item", id: id})

      assert %{comment: 1} = Notifications.unread_counts(author.id)
    end

    test "invalid tab and scope report domain errors", %{author: author} do
      assert {:error, :invalid_tab} = Notifications.list_notifications(author.id, "bogus")
      assert {:error, :invalid_tab} = Notifications.unread_count(author.id, "bogus")

      assert {:error, :invalid_tab} =
               Notifications.mark_as_read(author.id, %{scope: "tab", tab: "bogus"})

      assert {:error, :invalid_scope} = Notifications.mark_as_read(author.id, %{scope: "all"})
    end
  end
end
