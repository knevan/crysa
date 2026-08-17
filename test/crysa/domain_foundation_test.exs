defmodule Crysa.DomainFoundationTest do
  use ExUnit.Case, async: true

  alias Crysa.Accounts.User
  alias Crysa.Catalog.{Category, Chapter, Series}
  alias Crysa.Comments.Comment
  alias Crysa.Library.Rating
  alias Crysa.Moderation.Report

  test "user create changeset normalizes email and enforces required account fields" do
    changeset =
      User.create_changeset(%User{}, %{
        email: " Admin@Example.COM ",
        username: " admin ",
        password_hash: String.duplicate("x", 40),
        role_id: 1
      })

    assert changeset.valid?
    assert Ecto.Changeset.get_change(changeset, :email) == "admin@example.com"
    assert Ecto.Changeset.get_change(changeset, :username) == "admin"
  end

  test "category changeset stores normalized uniqueness key" do
    changeset = Category.changeset(%Category{}, %{name: "  Action   Comedy "})

    assert changeset.valid?
    assert Ecto.Changeset.get_change(changeset, :normalized_name) == "action comedy"
  end

  test "series changeset validates separated publication and processing statuses" do
    changeset =
      Series.create_changeset(%Series{}, %{
        title: "Example Series",
        slug: "Example Series",
        source_url: "https://example.test/series/example",
        publication_status: "ongoing",
        processing_status: "available"
      })

    assert changeset.valid?
    assert Ecto.Changeset.get_change(changeset, :slug) == "example-series"
  end

  test "chapter changeset uses chapter_key as required identity" do
    changeset =
      Chapter.changeset(%Chapter{}, %{
        series_id: 1,
        chapter_key: "10-2",
        display_number: "10 Part 2",
        sort_key: "000010-000002",
        source_url: "https://example.test/chapter/10-2"
      })

    assert changeset.valid?
  end

  test "rating changeset bounds rating values" do
    changeset = Rating.changeset(%Rating{}, %{user_id: 1, series_id: 1, rating: 6})

    refute changeset.valid?

    assert {_, [validation: :number, kind: :less_than_or_equal_to, number: 5]} =
             changeset.errors[:rating]
  end

  test "comment changeset requires exactly one target" do
    attrs = %{user_id: 1, body_markdown: "hello", body_html: "<p>hello</p>"}

    refute Comment.create_changeset(%Comment{}, attrs).valid?
    assert Comment.create_changeset(%Comment{}, Map.put(attrs, :series_id, 1)).valid?
    assert Comment.create_changeset(%Comment{}, Map.put(attrs, :chapter_id, 1)).valid?

    refute Comment.create_changeset(%Comment{}, Map.merge(attrs, %{series_id: 1, chapter_id: 1})).valid?
  end

  test "report changeset requires exactly one moderation target" do
    attrs = %{reporter_id: 1, reason: "spam"}

    refute Report.create_changeset(%Report{}, attrs).valid?
    assert Report.create_changeset(%Report{}, Map.put(attrs, :chapter_id, 1)).valid?
    assert Report.create_changeset(%Report{}, Map.put(attrs, :comment_id, 1)).valid?

    refute Report.create_changeset(%Report{}, Map.merge(attrs, %{chapter_id: 1, comment_id: 1})).valid?
  end
end
