defmodule Crysa.Comments.Query do
  @moduledoc """
  Read-model queries for comments, votes, and attachments.

  Provides bounded pagination, stable ordering, and filters for soft-deleted
  comments. All pagination inputs are clamped to safe ranges.
  """

  import Ecto.Query

  alias Crysa.Comments.{Attachment, Comment, Vote}
  alias Crysa.Pagination
  alias Crysa.Repo

  @default_page_size 20
  @max_page_size 50

  @spec list_comments_for_series(integer(), map()) :: {[Comment.t()], Pagination.t()}
  def list_comments_for_series(series_id, params \\ %{})
      when is_integer(series_id) and is_map(params) do
    base =
      from(c in Comment,
        where: c.series_id == ^series_id and is_nil(c.deleted_at),
        order_by: [asc: c.inserted_at, asc: c.id],
        preload: [:user]
      )

    paginate(base, params, @default_page_size, @max_page_size)
  end

  @spec list_comments_for_chapter(integer(), map()) :: {[Comment.t()], Pagination.t()}
  def list_comments_for_chapter(chapter_id, params \\ %{})
      when is_integer(chapter_id) and is_map(params) do
    base =
      from(c in Comment,
        where: c.chapter_id == ^chapter_id and is_nil(c.deleted_at),
        order_by: [asc: c.inserted_at, asc: c.id],
        preload: [:user]
      )

    paginate(base, params, @default_page_size, @max_page_size)
  end

  @spec list_replies(integer(), map()) :: {[Comment.t()], Pagination.t()}
  def list_replies(parent_id, params \\ %{}) when is_integer(parent_id) and is_map(params) do
    base =
      from(c in Comment,
        where: c.parent_id == ^parent_id and is_nil(c.deleted_at),
        order_by: [asc: c.inserted_at, asc: c.id],
        preload: [:user]
      )

    paginate(base, params, @default_page_size, @max_page_size)
  end

  @spec list_thread(integer()) :: [Comment.t()]
  def list_thread(root_id) when is_integer(root_id) do
    from(c in Comment,
      where: c.parent_id == ^root_id and is_nil(c.deleted_at),
      order_by: [asc: c.inserted_at, asc: c.id],
      preload: [:user]
    )
    |> Repo.all()
  end

  @spec get_comment(integer()) :: Comment.t() | nil
  def get_comment(id) when is_integer(id) do
    from(c in Comment, where: c.id == ^id, preload: [:user])
    |> Repo.one()
  end

  @spec get_comment_with_votes(integer()) :: Comment.t() | nil
  def get_comment_with_votes(id) when is_integer(id) do
    from(c in Comment, where: c.id == ^id, preload: [:user, :votes])
    |> Repo.one()
  end

  @spec count_comments_for_series(integer()) :: non_neg_integer()
  def count_comments_for_series(series_id) when is_integer(series_id) do
    from(c in Comment, where: c.series_id == ^series_id and is_nil(c.deleted_at))
    |> Repo.aggregate(:count, :id)
  end

  @spec count_comments_for_chapter(integer()) :: non_neg_integer()
  def count_comments_for_chapter(chapter_id) when is_integer(chapter_id) do
    from(c in Comment, where: c.chapter_id == ^chapter_id and is_nil(c.deleted_at))
    |> Repo.aggregate(:count, :id)
  end

  # Votes

  @spec get_vote(integer(), integer()) :: Vote.t() | nil
  def get_vote(user_id, comment_id) when is_integer(user_id) and is_integer(comment_id) do
    Repo.get_by(Vote, user_id: user_id, comment_id: comment_id)
  end

  @spec list_votes(integer()) :: [Vote.t()]
  def list_votes(comment_id) when is_integer(comment_id) do
    from(v in Vote, where: v.comment_id == ^comment_id)
    |> Repo.all()
  end

  # Attachments

  @spec list_attachments(integer()) :: [Attachment.t()]
  def list_attachments(comment_id) when is_integer(comment_id) do
    from(a in Attachment,
      join: c in Comment,
      on: c.id == a.comment_id,
      where: a.comment_id == ^comment_id and is_nil(c.deleted_at),
      order_by: [asc: a.inserted_at]
    )
    |> Repo.all()
  end

  # Pagination Helpers

  defp paginate(query, params, default_size, max_size) do
    page = parse_page(params)
    page_size = parse_page_size(params, default_size, max_size)
    total = Repo.aggregate(query, :count, :id)
    page = clamp_page(page, page_size, total)

    results =
      query
      |> limit(^page_size)
      |> offset(^((page - 1) * page_size))
      |> Repo.all()

    {results, Pagination.build(page, page_size, total)}
  end

  defp parse_page(params) do
    case parse_integer(params, "page", 1) do
      page when page > 0 -> page
      _ -> 1
    end
  end

  defp clamp_page(page, page_size, total) do
    total_pages = max(div(total + page_size - 1, page_size), 1)
    min(page, total_pages)
  end

  defp parse_page_size(params, default, max) do
    params
    |> parse_integer("page_size", default)
    |> clamp(1, max)
  end

  defp parse_integer(params, key, default) do
    case params do
      %{^key => value} when is_integer(value) ->
        value

      %{^key => value} when is_binary(value) ->
        case Integer.parse(value) do
          {int, ""} -> int
          _ -> default
        end

      _ ->
        default
    end
  end

  defp clamp(value, min, _max) when value < min, do: min
  defp clamp(value, _min, max) when value > max, do: max
  defp clamp(value, _min, _max), do: value
end
