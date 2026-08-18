defmodule Crysa.DbConstraintsTest do
  use Crysa.DataCase, async: false

  alias Crysa.Accounts.Role
  alias Crysa.AccountsFixtures
  alias Crysa.Catalog.{Chapter, ChapterImage, Series}
  alias Crysa.Comments.{Comment, Vote}
  alias Crysa.Library.{Bookmark, Rating}
  alias Crysa.Moderation.Report
  alias Crysa.Notifications.Notification

  setup do
    role = insert_role("user")
    user = insert_user(role, "user-#{unique()}@example.com")
    series = insert_series(%{})
    %{role: role, user: user, series: series}
  end

  describe "unique constraints" do
    test "users.email is unique case-insensitively", %{user: user} do
      attrs = %{
        email: String.upcase(user.email),
        username: "other#{unique()}"
      }

      assert_raise Ecto.ConstraintError, ~r/users_lower_email_index/, fn ->
        AccountsFixtures.user_fixture(attrs)
      end
    end

    test "users.username is unique case-insensitively", %{user: user} do
      attrs = %{
        email: "other#{unique()}@example.com",
        username: String.upcase(user.username)
      }

      assert_raise Ecto.ConstraintError, ~r/users_lower_username_index/, fn ->
        AccountsFixtures.user_fixture(attrs)
      end
    end
  end

  describe "check constraints" do
    test "rating is enforced by the database", %{user: user, series: series} do
      too_low =
        %Rating{} |> Ecto.Changeset.change(%{user_id: user.id, series_id: series.id, rating: 0})

      too_high =
        %Rating{} |> Ecto.Changeset.change(%{user_id: user.id, series_id: series.id, rating: 6})

      assert_raise Ecto.ConstraintError, ~r/rating_between_1_and_5/, fn ->
        Repo.insert!(too_low)
      end

      assert_raise Ecto.ConstraintError, ~r/rating_between_1_and_5/, fn ->
        Repo.insert!(too_high)
      end
    end

    test "comment vote value is enforced by the database", %{user: user, series: series} do
      comment = insert_comment(series, %{user_id: user.id})

      invalid =
        %Vote{}
        |> Ecto.Changeset.change(%{user_id: user.id, comment_id: comment.id, vote: 0})

      assert_raise Ecto.ConstraintError, ~r/comment_votes_vote_value/, fn ->
        Repo.insert!(invalid)
      end
    end

    test "series publication status is enforced by the database" do
      now = DateTime.utc_now()

      assert_raise Postgrex.Error, ~r/check constraint.*series_publication_status_check/i, fn ->
        Repo.insert_all(Series, [
          %{
            title: "Bogus Status",
            slug: "bogus-status-#{unique()}",
            source_url: "https://example.test/bogus-#{unique()}",
            publication_status: "bogus",
            processing_status: "pending",
            inserted_at: now,
            updated_at: now
          }
        ])
      end
    end

    test "report status is enforced by the database", %{user: user, series: series} do
      chapter = insert_chapter(series, %{})

      assert_raise Postgrex.Error, ~r/check constraint.*reports_status_check/i, fn ->
        now = DateTime.utc_now()

        Repo.insert_all(Report, [
          %{
            reporter_id: user.id,
            chapter_id: chapter.id,
            reason: "spam",
            status: "bogus",
            inserted_at: now,
            updated_at: now
          }
        ])
      end
    end

    test "notification action is enforced by the database", %{user: user, series: series} do
      comment = insert_comment(series, %{user_id: user.id})

      assert_raise Postgrex.Error, ~r/check constraint.*notifications_action_check/i, fn ->
        now = DateTime.utc_now()

        Repo.insert_all(Notification, [
          %{
            recipient_id: user.id,
            comment_id: comment.id,
            action: "bogus",
            inserted_at: now,
            updated_at: now
          }
        ])
      end
    end
  end

  describe "single target constraints" do
    test "comment must target exactly one of series or chapter", %{user: user, series: series} do
      chapter = insert_chapter(series, %{})

      both =
        %Comment{}
        |> Ecto.Changeset.change(%{
          user_id: user.id,
          series_id: series.id,
          chapter_id: chapter.id,
          body_markdown: "x",
          body_html: "<p>x</p>"
        })

      none =
        %Comment{}
        |> Ecto.Changeset.change(%{user_id: user.id, body_markdown: "x", body_html: "<p>x</p>"})

      assert_raise Ecto.ConstraintError, ~r/comments_single_target/, fn -> Repo.insert!(both) end
      assert_raise Ecto.ConstraintError, ~r/comments_single_target/, fn -> Repo.insert!(none) end
    end

    test "report must target exactly one of chapter or comment", %{user: user, series: series} do
      chapter = insert_chapter(series, %{})
      comment = insert_comment(series, %{user_id: user.id})

      both =
        %Report{}
        |> Ecto.Changeset.change(%{
          reporter_id: user.id,
          chapter_id: chapter.id,
          comment_id: comment.id,
          reason: "spam"
        })

      none = %Report{} |> Ecto.Changeset.change(%{reporter_id: user.id, reason: "spam"})

      assert_raise Ecto.ConstraintError, ~r/reports_single_target/, fn -> Repo.insert!(both) end
      assert_raise Ecto.ConstraintError, ~r/reports_single_target/, fn -> Repo.insert!(none) end
    end
  end

  describe "foreign key behavior" do
    test "deleting a series cascades to chapters, images, and bookmarks", %{
      user: user,
      series: series
    } do
      chapter = insert_chapter(series, %{})
      insert_image(chapter)
      insert_bookmark(user, series)

      assert {:ok, _} = Repo.delete(series)

      assert Repo.get(Chapter, chapter.id) == nil
      assert Repo.all(from(i in ChapterImage, where: i.chapter_id == ^chapter.id)) == []
      assert Repo.all(from(b in Bookmark, where: b.series_id == ^series.id)) == []
    end

    test "deleting a comment with replies is restricted", %{user: user, series: series} do
      parent = insert_comment(series, %{user_id: user.id})
      reply = insert_comment(series, %{user_id: user.id, parent_id: parent.id})

      assert_raise Ecto.ConstraintError, ~r/comments_parent_id_fkey/, fn ->
        Repo.delete!(parent)
      end

      assert Repo.get(Comment, parent.id) != nil
      assert Repo.get(Comment, reply.id) != nil
    end

    test "deleting a user leaves comments anonymous", %{role: role, user: user, series: series} do
      _ = role
      comment = insert_comment(series, %{user_id: user.id})

      assert {:ok, _} = Repo.delete(user)

      reloaded = Repo.get!(Comment, comment.id)
      assert reloaded.user_id == nil
    end

    test "soft-deleting a parent comment keeps the reply tree alive", %{
      user: user,
      series: series
    } do
      parent = insert_comment(series, %{user_id: user.id})
      reply = insert_comment(series, %{user_id: user.id, parent_id: parent.id})

      assert {:ok, _} =
               parent
               |> Comment.soft_delete_changeset(%{
                 deleted_at: DateTime.utc_now(),
                 deleted_by_id: user.id
               })
               |> Repo.update()

      assert Repo.get(Comment, parent.id) != nil
      assert Repo.get(Comment, reply.id) != nil
      assert Repo.get!(Comment, parent.id).deleted_at != nil
    end
  end

  defp insert_role(name) do
    Repo.insert!(%Role{} |> Ecto.Changeset.change(%{name: name}))
  end

  defp insert_user(role, email) do
    attrs = %{
      email: email,
      username: "user#{unique()}",
      role_id: role.id
    }

    AccountsFixtures.user_fixture(attrs)
  end

  defp insert_series(attrs) do
    defaults = %{
      title: "Series #{unique()}",
      slug: "series-#{unique()}",
      source_url: "https://example.test/series/#{unique()}",
      publication_status: "ongoing",
      processing_status: "pending"
    }

    Repo.insert!(Series.create_changeset(%Series{}, Map.merge(defaults, attrs)))
  end

  defp insert_chapter(series, attrs) do
    defaults = %{
      series_id: series.id,
      chapter_key: "ch#{unique()}",
      display_number: "1",
      sort_key: "000001",
      source_url: "https://example.test/chapter/#{unique()}"
    }

    Repo.insert!(Chapter.create_changeset(%Chapter{}, Map.merge(defaults, attrs)))
  end

  defp insert_image(chapter) do
    Repo.insert!(
      ChapterImage.changeset(%ChapterImage{}, %{
        chapter_id: chapter.id,
        image_order: 1,
        source_url: "https://example.test/img/#{unique()}"
      })
    )
  end

  defp insert_bookmark(user, series) do
    Repo.insert!(Bookmark.changeset(%Bookmark{}, %{user_id: user.id, series_id: series.id}))
  end

  defp insert_comment(series, attrs) do
    defaults = %{
      user_id: nil,
      series_id: series.id,
      body_markdown: "comment #{unique()}",
      body_html: "<p>comment #{unique()}</p>"
    }

    Repo.insert!(Comment.create_changeset(%Comment{}, Map.merge(defaults, attrs)))
  end

  defp unique do
    System.unique_integer([:positive])
  end
end
