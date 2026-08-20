defmodule Crysa.ModerationTest do
  use Crysa.DataCase, async: false

  alias Crysa.AccountsFixtures
  alias Crysa.CatalogFixtures
  alias Crysa.Comments
  alias Crysa.Moderation

  setup do
    user = AccountsFixtures.user_fixture()
    moderator = AccountsFixtures.user_fixture(%{role_name: "moderator"})
    other = AccountsFixtures.user_fixture()
    series = CatalogFixtures.series_fixture()
    chapter = CatalogFixtures.chapter_fixture(series)

    {:ok, comment} =
      Comments.create_comment(%{user_id: user.id, series_id: series.id, body_markdown: "hello"})

    %{
      user: user,
      moderator: moderator,
      other: other,
      series: series,
      chapter: chapter,
      comment: comment
    }
  end

  describe "create_report/1" do
    test "allows chapter reasons for chapter target", %{user: user, chapter: chapter} do
      assert {:ok, rep} =
               Moderation.create_report(%{
                 reporter_id: user.id,
                 chapter_id: chapter.id,
                 reason: "broken_image"
               })

      assert rep.reason == "broken_image"
    end

    test "allows comment reasons for comment target", %{user: user, comment: comment} do
      assert {:ok, rep} =
               Moderation.create_report(%{
                 reporter_id: user.id,
                 comment_id: comment.id,
                 reason: "toxic"
               })

      assert rep.reason == "toxic"
    end

    test "rejects chapter reason for comment", %{user: user, comment: comment} do
      assert {:error, cs} =
               Moderation.create_report(%{
                 reporter_id: user.id,
                 comment_id: comment.id,
                 reason: "broken_image"
               })

      assert cs.errors[:reason]
    end

    test "rejects comment reason for chapter", %{user: user, chapter: chapter} do
      assert {:error, cs} =
               Moderation.create_report(%{
                 reporter_id: user.id,
                 chapter_id: chapter.id,
                 reason: "toxic"
               })

      assert cs.errors[:reason]
    end

    test "other is allowed for both targets", %{user: user, chapter: chapter, comment: comment} do
      assert {:ok, _} =
               Moderation.create_report(%{
                 reporter_id: user.id,
                 chapter_id: chapter.id,
                 reason: "other"
               })

      assert {:ok, _} =
               Moderation.create_report(%{
                 reporter_id: user.id,
                 comment_id: comment.id,
                 reason: "other"
               })
    end

    test "requires exactly one target", %{user: user, chapter: chapter, comment: comment} do
      assert {:error, cs} = Moderation.create_report(%{reporter_id: user.id, reason: "other"})
      assert cs.errors[:base]

      assert {:error, cs} =
               Moderation.create_report(%{
                 reporter_id: user.id,
                 chapter_id: chapter.id,
                 comment_id: comment.id,
                 reason: "other"
               })

      assert cs.errors[:base]
    end
  end

  describe "resolve_report/3" do
    test "moderator can resolve pending to resolved", %{
      user: user,
      moderator: moderator,
      chapter: chapter
    } do
      {:ok, rep} =
        Moderation.create_report(%{
          reporter_id: user.id,
          chapter_id: chapter.id,
          reason: "broken_image"
        })

      assert {:ok, resolved} =
               Moderation.resolve_report(rep, moderator, %{
                 status: "resolved",
                 resolution_note: "fixed"
               })

      assert resolved.status == "resolved"
      assert resolved.resolved_by_id == moderator.id
      assert resolved.resolved_at != nil
    end

    test "forces pending status to resolved", %{
      user: user,
      moderator: moderator,
      chapter: chapter
    } do
      {:ok, rep} =
        Moderation.create_report(%{reporter_id: user.id, chapter_id: chapter.id, reason: "other"})

      assert {:ok, resolved} = Moderation.resolve_report(rep, moderator, %{status: "pending"})
      assert resolved.status == "resolved"
    end

    test "non-moderator cannot resolve", %{user: user, other: other, chapter: chapter} do
      {:ok, rep} =
        Moderation.create_report(%{reporter_id: user.id, chapter_id: chapter.id, reason: "other"})

      assert {:error, :unauthorized} =
               Moderation.resolve_report(rep, other, %{status: "resolved"})
    end

    test "already resolved returns error", %{user: user, moderator: moderator, chapter: chapter} do
      {:ok, rep} =
        Moderation.create_report(%{reporter_id: user.id, chapter_id: chapter.id, reason: "other"})

      {:ok, resolved} = Moderation.resolve_report(rep, moderator, %{status: "resolved"})

      assert {:error, :already_resolved} =
               Moderation.resolve_report(resolved, moderator, %{status: "rejected"})
    end

    test "mark_resolved and mark_rejected helpers", %{
      user: user,
      moderator: moderator,
      chapter: chapter
    } do
      {:ok, r1} =
        Moderation.create_report(%{reporter_id: user.id, chapter_id: chapter.id, reason: "other"})

      assert {:ok, res} = Moderation.mark_resolved(r1, moderator)
      assert res.status == "resolved"

      {:ok, r2} =
        Moderation.create_report(%{reporter_id: user.id, chapter_id: chapter.id, reason: "other"})

      assert {:ok, rej} = Moderation.mark_rejected(r2, moderator, %{resolution_note: "invalid"})
      assert rej.status == "rejected"
    end
  end

  describe "listing" do
    test "lists pending reports", %{user: user, moderator: moderator, chapter: chapter} do
      {:ok, _} =
        Moderation.create_report(%{reporter_id: user.id, chapter_id: chapter.id, reason: "other"})

      {:ok, r2} =
        Moderation.create_report(%{
          reporter_id: user.id,
          chapter_id: chapter.id,
          reason: "broken_image"
        })

      {:ok, _} = Moderation.resolve_report(r2, moderator, %{status: "resolved"})

      {pending, _} = Moderation.list_pending_reports()
      assert Enum.all?(pending, &(&1.status == "pending"))

      {all, _} = Moderation.list_reports(%{"status" => "resolved"})
      assert Enum.all?(all, &(&1.status == "resolved"))
    end
  end
end
