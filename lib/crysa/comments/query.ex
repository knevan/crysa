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
  @max_tree_depth 10
  @max_tree_nodes 500

  @spec list_comments_for_series(integer(), map()) :: {[Comment.t()], Pagination.t()}
  def list_comments_for_series(series_id, params \\ %{})
      when is_integer(series_id) and is_map(params) do
    sort = parse_comment_sort(params)

    base =
      from(c in Comment,
        where: c.series_id == ^series_id and is_nil(c.deleted_at),
        preload: [:user]
      )
      |> order_comments(sort)

    paginate(base, params, @default_page_size, @max_page_size)
  end

  defp parse_comment_sort(%{"sort" => sort}) when sort in ~w(newest oldest most_voted) do
    case sort do
      "newest" -> :newest
      "oldest" -> :oldest
      "most_voted" -> :most_voted
      _ -> :newest
    end
  end

  defp parse_comment_sort(_), do: :newest

  defp order_comments(query, :oldest), do: order_by(query, [c], asc: c.inserted_at, asc: c.id)

  defp order_comments(query, :most_voted),
    do: order_by(query, [c], desc: c.vote_score, desc: c.inserted_at, desc: c.id)

  defp order_comments(query, _), do: order_by(query, [c], desc: c.inserted_at, desc: c.id)

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

  @doc """
  Returns a single thread subtree rooted at `thread_id` (the parent before "More replies").
  Used to implement "Continue this thread" where the parent becomes the new head at depth 0.
  Includes the root itself plus all descendants BFS up to `@max_tree_depth`.
  Returns `{[Comment.t()], Pagination.t()}` where pagination is for the thread root (single entry).
  """
  @spec list_thread_tree(integer()) :: {[Comment.t()], Pagination.t()}
  def list_thread_tree(thread_id) when is_integer(thread_id) do
    case Repo.get(Comment, thread_id) |> Repo.preload(:user) do
      nil ->
        {[], Pagination.build(1, @default_page_size, 0)}

      %Comment{} = root ->
        descendants = fetch_thread_descendants(root)
        all = [root | descendants]
        pagination = Pagination.build(1, @default_page_size, 1)
        {all, pagination}
    end
  end

  defp fetch_thread_descendants(%Comment{
         id: root_id,
         series_id: series_id,
         chapter_id: chapter_id
       }) do
    # Determine filter by series or chapter to keep thread within same target
    fetch_fun =
      cond do
        not is_nil(series_id) ->
          fn parent_ids ->
            from(c in Comment,
              where: c.series_id == ^series_id and c.parent_id in ^parent_ids,
              order_by: [asc: c.inserted_at, asc: c.id],
              preload: [:user]
            )
            |> Repo.all()
          end

        not is_nil(chapter_id) ->
          fn parent_ids ->
            from(c in Comment,
              where: c.chapter_id == ^chapter_id and c.parent_id in ^parent_ids,
              order_by: [asc: c.inserted_at, asc: c.id],
              preload: [:user]
            )
            |> Repo.all()
          end

        true ->
          fn _parent_ids -> [] end
      end

    fetch_descendants_recursive(fetch_fun, [root_id], [], MapSet.new([root_id]), 0)
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

  # Tree — threaded view

  @doc """
  Returns all comment nodes for a series page as a flat list plus pagination for roots.

  Roots are paginated (`parent_id IS NULL`) and ordered by `sort` (newest/oldest/most_voted).
  All descendants of the paginated roots are fetched breadth-first up to `@max_tree_depth`
  and `@max_tree_nodes`, ordered chronologically. Soft-deleted comments are included
  so the reply tree stays intact; callers should render them as `[deleted]` placeholders.
  """
  @spec list_comment_tree_for_series(integer(), map()) :: {[Comment.t()], Pagination.t()}
  def list_comment_tree_for_series(series_id, params \\ %{})
      when is_integer(series_id) and is_map(params) do
    sort = parse_comment_sort(params)
    page = parse_page(params)
    page_size = parse_page_size(params, @default_page_size, @max_page_size)

    root_base = from(c in Comment, where: c.series_id == ^series_id and is_nil(c.parent_id))
    total_roots = Repo.aggregate(root_base, :count, :id)
    page = clamp_page(page, page_size, total_roots)

    roots =
      root_base
      |> order_comments(sort)
      |> limit(^page_size)
      |> offset(^((page - 1) * page_size))
      |> preload([:user])
      |> Repo.all()

    root_ids = Enum.map(roots, & &1.id)

    descendants =
      if root_ids == [] do
        []
      else
        fetch_descendants_for_series(series_id, root_ids)
      end

    all_nodes = roots ++ descendants
    pagination = Pagination.build(page, page_size, total_roots)
    {all_nodes, pagination}
  end

  @doc """
  Same as `list_comment_tree_for_series/2` but for chapter threads.
  """
  @spec list_comment_tree_for_chapter(integer(), map()) :: {[Comment.t()], Pagination.t()}
  def list_comment_tree_for_chapter(chapter_id, params \\ %{})
      when is_integer(chapter_id) and is_map(params) do
    page = parse_page(params)
    page_size = parse_page_size(params, @default_page_size, @max_page_size)

    root_base = from(c in Comment, where: c.chapter_id == ^chapter_id and is_nil(c.parent_id))
    total_roots = Repo.aggregate(root_base, :count, :id)
    page = clamp_page(page, page_size, total_roots)

    roots =
      root_base
      |> order_by([c], asc: c.inserted_at, asc: c.id)
      |> limit(^page_size)
      |> offset(^((page - 1) * page_size))
      |> preload([:user])
      |> Repo.all()

    root_ids = Enum.map(roots, & &1.id)

    descendants =
      if root_ids == [] do
        []
      else
        fetch_descendants_for_chapter(chapter_id, root_ids)
      end

    all_nodes = roots ++ descendants
    pagination = Pagination.build(page, page_size, total_roots)
    {all_nodes, pagination}
  end

  defp fetch_descendants_for_series(series_id, root_ids) do
    fetch_descendants_recursive(
      fn parent_ids ->
        from(c in Comment,
          where: c.series_id == ^series_id and c.parent_id in ^parent_ids,
          order_by: [asc: c.inserted_at, asc: c.id],
          preload: [:user]
        )
        |> Repo.all()
      end,
      root_ids,
      [],
      MapSet.new(root_ids),
      0
    )
  end

  defp fetch_descendants_for_chapter(chapter_id, root_ids) do
    fetch_descendants_recursive(
      fn parent_ids ->
        from(c in Comment,
          where: c.chapter_id == ^chapter_id and c.parent_id in ^parent_ids,
          order_by: [asc: c.inserted_at, asc: c.id],
          preload: [:user]
        )
        |> Repo.all()
      end,
      root_ids,
      [],
      MapSet.new(root_ids),
      0
    )
  end

  defp fetch_descendants_recursive(_fetch_fun, [], acc, _seen, _depth), do: acc

  defp fetch_descendants_recursive(_fetch_fun, _parent_ids, acc, _seen, depth)
       when depth >= @max_tree_depth,
       do: acc

  defp fetch_descendants_recursive(fetch_fun, parent_ids, acc, seen, depth) do
    children = fetch_fun.(parent_ids)

    if children == [] do
      acc
    else
      new_ids =
        children
        |> Enum.map(& &1.id)
        |> Enum.reject(&MapSet.member?(seen, &1))

      if new_ids == [] do
        acc ++ children
      else
        new_seen = Enum.reduce(new_ids, seen, &MapSet.put(&2, &1))
        # Bound total nodes to avoid explosion on mega-threads
        remaining = @max_tree_nodes - length(acc)

        children_to_keep =
          if length(children) > remaining do
            Enum.take(children, max(remaining, 0))
          else
            children
          end

        if length(acc) + length(children_to_keep) >= @max_tree_nodes do
          acc ++ children_to_keep
        else
          fetch_descendants_recursive(
            fetch_fun,
            new_ids,
            acc ++ children_to_keep,
            new_seen,
            depth + 1
          )
        end
      end
    end
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

  @doc """
  Returns vote counts per comment for a list of comment ids.
  Result is `%{comment_id => %{up: non_neg_integer(), down: non_neg_integer()}}`
  with `0` defaults for comments without votes. Used to display separate
  up/down counts (`▲ 1 ▼ 2`) instead of net `vote_score`.
  """
  @spec vote_counts_for_comment_ids([integer()]) :: %{
          integer() => %{up: non_neg_integer(), down: non_neg_integer()}
        }
  def vote_counts_for_comment_ids([]), do: %{}

  def vote_counts_for_comment_ids(ids) when is_list(ids) do
    counts =
      from(v in Vote,
        where: v.comment_id in ^ids,
        group_by: [v.comment_id, v.vote],
        select: {v.comment_id, v.vote, count(v.vote)}
      )
      |> Repo.all()
      |> Enum.reduce(%{}, fn {cid, vote, cnt}, acc ->
        existing = Map.get(acc, cid, %{up: 0, down: 0})

        updated =
          case vote do
            1 -> %{existing | up: cnt}
            -1 -> %{existing | down: cnt}
            _ -> existing
          end

        Map.put(acc, cid, updated)
      end)

    Enum.reduce(ids, counts, fn id, acc -> Map.put_new(acc, id, %{up: 0, down: 0}) end)
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
