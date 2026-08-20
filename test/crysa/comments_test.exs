defmodule Crysa.CommentsTest do
  use Crysa.DataCase, async: false

  alias Crysa.AccountsFixtures
  alias Crysa.CatalogFixtures
  alias Crysa.Comments
  alias Crysa.Comments.Comment

  setup do
    user = AccountsFixtures.user_fixture()
    other = AccountsFixtures.user_fixture()
    moderator = AccountsFixtures.user_fixture(%{role_name: "moderator"})
    series = CatalogFixtures.series_fixture()
    chapter = CatalogFixtures.chapter_fixture(series)
    %{user: user, other: other, moderator: moderator, series: series, chapter: chapter}
  end

  describe "create_comment/1" do
    test "creates comment with sanitized html from markdown", %{user: user, series: series} do
      {:ok, comment} =
        Comments.create_comment(%{
          user_id: user.id,
          series_id: series.id,
          body_markdown: "Hello **world**"
        })

      assert comment.body_markdown == "Hello **world**"
      assert comment.body_html == "<p>Hello <strong>world</strong></p>"
    end

    test "sanitizes XSS payload in markdown", %{user: user, series: series} do
      {:ok, comment} =
        Comments.create_comment(%{
          user_id: user.id,
          series_id: series.id,
          body_markdown: "<script>alert(1)</script>"
        })

      refute comment.body_html =~ "<script>"
      assert comment.body_html =~ "&lt;script&gt;"
    end

    test "requires exactly one target", %{user: user, series: series, chapter: chapter} do
      assert {:error, cs} =
               Comments.create_comment(%{
                 user_id: user.id,
                 series_id: series.id,
                 chapter_id: chapter.id,
                 body_markdown: "x"
               })

      assert cs.errors[:base]

      assert {:error, cs} = Comments.create_comment(%{user_id: user.id, body_markdown: "x"})
      assert cs.errors[:base]
    end

    test "validates parent existence and target match", %{
      user: user,
      other: other,
      series: series,
      chapter: chapter
    } do
      {:ok, parent} =
        Comments.create_comment(%{
          user_id: user.id,
          series_id: series.id,
          body_markdown: "parent"
        })

      {:ok, _reply} =
        Comments.create_comment(%{
          user_id: other.id,
          series_id: series.id,
          parent_id: parent.id,
          body_markdown: "reply"
        })

      assert {:error, :parent_not_found} =
               Comments.create_comment(%{
                 user_id: other.id,
                 series_id: series.id,
                 parent_id: 999_999,
                 body_markdown: "x"
               })

      assert {:error, :parent_target_mismatch} =
               Comments.create_comment(%{
                 user_id: other.id,
                 chapter_id: chapter.id,
                 parent_id: parent.id,
                 body_markdown: "x"
               })
    end

    test "rejects reply to deleted parent", %{user: user, other: other, series: series} do
      {:ok, parent} =
        Comments.create_comment(%{
          user_id: user.id,
          series_id: series.id,
          body_markdown: "parent"
        })

      {:ok, _} = Comments.soft_delete_comment(parent, user)

      assert {:error, :parent_deleted} =
               Comments.create_comment(%{
                 user_id: other.id,
                 series_id: series.id,
                 parent_id: parent.id,
                 body_markdown: "reply"
               })
    end
  end

  describe "update_comment/3" do
    test "allows author to edit markdown and regenerates html", %{user: user, series: series} do
      {:ok, comment} =
        Comments.create_comment(%{user_id: user.id, series_id: series.id, body_markdown: "orig"})

      {:ok, updated} = Comments.update_comment(comment, %{body_markdown: "edited **bold**"}, user)
      assert updated.body_markdown == "edited **bold**"
      assert updated.body_html =~ "<strong>bold</strong>"
    end

    test "ignores client-provided body_html (stored XSS protection)", %{
      user: user,
      series: series
    } do
      {:ok, comment} =
        Comments.create_comment(%{user_id: user.id, series_id: series.id, body_markdown: "orig"})

      {:ok, updated} =
        Comments.update_comment(comment, %{"body_html" => "<script>alert(1)</script>"}, user)

      # body_html must remain the original sanitized version, not the injected one
      refute updated.body_html =~ "<script>"
      assert updated.body_html == "<p>orig</p>"
    end

    test "rejects update by non-author", %{user: user, other: other, series: series} do
      {:ok, comment} =
        Comments.create_comment(%{user_id: user.id, series_id: series.id, body_markdown: "orig"})

      assert {:error, :unauthorized} =
               Comments.update_comment(comment, %{body_markdown: "hacked"}, other)
    end

    test "rejects update on deleted comment even with stale struct", %{user: user, series: series} do
      {:ok, comment} =
        Comments.create_comment(%{user_id: user.id, series_id: series.id, body_markdown: "orig"})

      {:ok, _deleted} = Comments.soft_delete_comment(comment, user)
      # use stale original struct
      assert {:error, :deleted} = Comments.update_comment(comment, %{body_markdown: "edit"}, user)
    end
  end

  describe "soft_delete_comment/2" do
    test "author can soft-delete own comment", %{user: user, series: series} do
      {:ok, comment} =
        Comments.create_comment(%{user_id: user.id, series_id: series.id, body_markdown: "x"})

      assert {:ok, deleted} = Comments.soft_delete_comment(comment, user)
      assert deleted.deleted_at != nil
      assert deleted.deleted_by_id == user.id
    end

    test "moderator can delete any comment", %{user: user, moderator: moderator, series: series} do
      {:ok, comment} =
        Comments.create_comment(%{user_id: user.id, series_id: series.id, body_markdown: "x"})

      assert {:ok, _} = Comments.soft_delete_comment(comment, moderator)
    end

    test "other user cannot delete", %{user: user, other: other, series: series} do
      {:ok, comment} =
        Comments.create_comment(%{user_id: user.id, series_id: series.id, body_markdown: "x"})

      assert {:error, :unauthorized} = Comments.soft_delete_comment(comment, other)
    end

    test "already deleted returns error even with stale struct", %{user: user, series: series} do
      {:ok, comment} =
        Comments.create_comment(%{user_id: user.id, series_id: series.id, body_markdown: "x"})

      {:ok, _} = Comments.soft_delete_comment(comment, user)
      assert {:error, :already_deleted} = Comments.soft_delete_comment(comment, user)
    end
  end

  describe "voting" do
    test "vote up, change, unvote and vote_score", %{user: user, other: other, series: series} do
      {:ok, comment} =
        Comments.create_comment(%{user_id: user.id, series_id: series.id, body_markdown: "vote"})

      assert {:ok, _} = Comments.vote_comment(other, comment, 1)
      assert %{vote_score: 1} = Comments.get_comment(comment.id)

      # idempotent same vote
      assert {:ok, _} = Comments.vote_comment(other, comment, 1)
      assert %{vote_score: 1} = Comments.get_comment(comment.id)

      assert {:ok, _} = Comments.vote_comment(other, comment, -1)
      assert %{vote_score: -1} = Comments.get_comment(comment.id)

      assert :ok = Comments.unvote_comment(other, comment)
      assert %{vote_score: 0} = Comments.get_comment(comment.id)

      # unvote idempotent
      assert :ok = Comments.unvote_comment(other, comment)
    end

    test "rejects vote on deleted comment", %{user: user, other: other, series: series} do
      {:ok, comment} =
        Comments.create_comment(%{user_id: user.id, series_id: series.id, body_markdown: "x"})

      {:ok, _} = Comments.soft_delete_comment(comment, user)
      assert {:error, :deleted} = Comments.vote_comment(other, comment, 1)
    end

    test "vote uniqueness per user", %{user: user, other: other, series: series} do
      {:ok, comment} =
        Comments.create_comment(%{user_id: user.id, series_id: series.id, body_markdown: "x"})

      {:ok, _} = Comments.vote_comment(user, comment, 1)
      {:ok, _} = Comments.vote_comment(other, comment, 1)
      assert %{vote_score: 2} = Comments.get_comment(comment.id)
    end
  end

  describe "attachments" do
    test "creates valid attachment", %{user: user, series: series} do
      {:ok, comment} =
        Comments.create_comment(%{user_id: user.id, series_id: series.id, body_markdown: "x"})

      assert {:ok, att} =
               Comments.create_attachment(
                 %{
                   comment_id: comment.id,
                   storage_key: "comments/#{comment.id}/a.webp",
                   content_type: "image/webp",
                   byte_size: 1000
                 },
                 user
               )

      assert att.storage_key =~ "a.webp"
    end

    test "rejects traversal, bad content_type, oversize", %{user: user, series: series} do
      {:ok, comment} =
        Comments.create_comment(%{user_id: user.id, series_id: series.id, body_markdown: "x"})

      assert {:error, cs} =
               Comments.create_attachment(
                 %{
                   comment_id: comment.id,
                   storage_key: "../evil",
                   content_type: "image/webp",
                   byte_size: 100
                 },
                 user
               )

      assert cs.errors[:storage_key]

      assert {:error, cs} =
               Comments.create_attachment(
                 %{
                   comment_id: comment.id,
                   storage_key: "a.webp",
                   content_type: "application/pdf",
                   byte_size: 100
                 },
                 user
               )

      assert cs.errors[:content_type]

      assert {:error, cs} =
               Comments.create_attachment(
                 %{
                   comment_id: comment.id,
                   storage_key: "a.webp",
                   content_type: "image/webp",
                   byte_size: 10_000_000
                 },
                 user
               )

      assert cs.errors[:byte_size]
    end

    test "rejects unauthorized and deleted comment", %{user: user, other: other, series: series} do
      {:ok, comment} =
        Comments.create_comment(%{user_id: user.id, series_id: series.id, body_markdown: "x"})

      assert {:error, :unauthorized} =
               Comments.create_attachment(
                 %{
                   comment_id: comment.id,
                   storage_key: "a.webp",
                   content_type: "image/webp",
                   byte_size: 100
                 },
                 other
               )

      {:ok, deleted} = Comments.soft_delete_comment(comment, user)

      assert {:error, :comment_deleted} =
               Comments.create_attachment(
                 %{
                   comment_id: deleted.id,
                   storage_key: "a.webp",
                   content_type: "image/webp",
                   byte_size: 100
                 },
                 user
               )

      assert [] == Comments.list_attachments(deleted)
    end
  end

  describe "listing" do
    test "excludes soft-deleted comments", %{user: user, series: series} do
      {:ok, c1} =
        Comments.create_comment(%{user_id: user.id, series_id: series.id, body_markdown: "keep"})

      {:ok, c2} =
        Comments.create_comment(%{
          user_id: user.id,
          series_id: series.id,
          body_markdown: "delete"
        })

      {:ok, _} = Comments.soft_delete_comment(c2, user)

      {list, _} = Comments.list_comments_for_series(series.id)
      assert Enum.map(list, & &1.id) == [c1.id]
    end

    test "pagination is bounded", %{user: user, series: series} do
      for i <- 1..3 do
        {:ok, _} =
          Comments.create_comment(%{
            user_id: user.id,
            series_id: series.id,
            body_markdown: "c#{i}"
          })
      end

      {page1, p1} = Comments.list_comments_for_series(series.id, %{"page" => 1, "page_size" => 2})
      assert [_, _] = page1
      assert p1.total_entries == 3
      {page2, _} = Comments.list_comments_for_series(series.id, %{"page" => 2, "page_size" => 2})
      assert [_] = page2
    end
  end

  # Ensure single-arity create_comment that leaks body_html is now impossible via changeset
  test "create_changeset ignores body_html", %{user: user, series: series} do
    cs =
      Comment.create_changeset(%Comment{}, %{
        user_id: user.id,
        series_id: series.id,
        body_markdown: "x",
        body_html: "<script>"
      })

    # body_html should be derived from markdown, not the injected value
    assert cs.changes[:body_html] == "<p>x</p>"
    refute cs.changes[:body_html] == "<script>"
  end

  test "update_changeset ignores body_html", %{user: user, series: series} do
    {:ok, c} =
      Comments.create_comment(%{user_id: user.id, series_id: series.id, body_markdown: "orig"})

    cs = Comment.update_changeset(c, %{"body_html" => "<script>alert(1)</script>"})
    # no body_html change, no body_markdown change -> no changes
    assert cs.changes == %{}
    # even with body_html injection, html stays original after update attempt
    {:ok, updated} = Comments.update_comment(c, %{"body_html" => "<script>"}, user)
    assert updated.body_html == "<p>orig</p>"
  end
end
