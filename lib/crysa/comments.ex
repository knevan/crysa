defmodule Crysa.Comments do
  @moduledoc """
  Comments context for comment threads, attachments, and votes.

  - Comments target exactly one `series` or `chapter` (enforced by DB CHECK).
  - Replies (`parent_id`) must target the same series/chapter as their parent.
  - Markdown is rendered server-side to sanitized HTML; client-provided HTML
    is never trusted (see `Crysa.Comments.Markdown`).
  - Soft deletion keeps the row for reply-tree integrity while hiding
    content; `deleted_at` + `deleted_by_id` are always set together.
  - Voting is transactional and maintains `comments.vote_score` atomically via
    `FOR UPDATE` row locks so concurrent voters never lose updates.
  """

  import Ecto.Query

  alias Crysa.Accounts.User
  alias Crysa.Comments.{Attachment, Comment, Markdown, Query, Vote}
  alias Crysa.Notifications
  alias Crysa.Repo

  @moderator_roles ~w(superadmin admin moderator)

  # Comments

  @doc """
  Creates a comment.

  `attrs` must contain `:user_id` (`:body_markdown` or `:body_html` via
  `Comment.create_changeset/2` will derive the other). When `parent_id` is
  present the parent is validated to exist, not be deleted, and target the
  same series/chapter as the new comment.

  Returns `{:error, :parent_not_found}`, `{:error, :parent_deleted}`,
  or `{:error, :parent_target_mismatch}` for bad replies.
  """
  @spec create_comment(map()) ::
          {:ok, Comment.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, :parent_not_found | :parent_deleted | :parent_target_mismatch}
  def create_comment(attrs) when is_map(attrs) do
    attrs = normalize_attrs(attrs)

    with :ok <- validate_parent(attrs),
         {:ok, comment} <- %Comment{} |> Comment.create_changeset(attrs) |> Repo.insert() do
      maybe_notify_reply(comment)
      {:ok, comment}
    end
  end

  @spec get_comment(integer()) :: Comment.t() | nil
  def get_comment(id) when is_integer(id), do: Query.get_comment(id)

  @spec get_comment!(integer()) :: Comment.t()
  def get_comment!(id) when is_integer(id), do: Repo.get!(Comment, id) |> Repo.preload(:user)

  @spec list_comments_for_series(integer(), map()) :: {[Comment.t()], Crysa.Pagination.t()}
  def list_comments_for_series(series_id, params \\ %{}),
    do: Query.list_comments_for_series(series_id, params)

  @spec list_comments_for_chapter(integer(), map()) :: {[Comment.t()], Crysa.Pagination.t()}
  def list_comments_for_chapter(chapter_id, params \\ %{}),
    do: Query.list_comments_for_chapter(chapter_id, params)

  @spec list_replies(integer(), map()) :: {[Comment.t()], Crysa.Pagination.t()}
  def list_replies(parent_id, params \\ %{}), do: Query.list_replies(parent_id, params)

  @spec count_comments_for_series(integer()) :: non_neg_integer()
  def count_comments_for_series(series_id), do: Query.count_comments_for_series(series_id)

  @spec count_comments_for_chapter(integer()) :: non_neg_integer()
  def count_comments_for_chapter(chapter_id), do: Query.count_comments_for_chapter(chapter_id)

  @doc """
  Updates a comment's markdown.

  Only the author may edit, and deleted comments cannot be edited.
  """
  @spec update_comment(Comment.t(), map(), User.t()) ::
          {:ok, Comment.t()} | {:error, Ecto.Changeset.t()} | {:error, :unauthorized | :deleted}
  def update_comment(%Comment{id: id}, attrs, %User{} = actor) do
    fresh = Repo.get!(Comment, id)

    cond do
      Comment.deleted?(fresh) ->
        {:error, :deleted}

      fresh.user_id != actor.id ->
        {:error, :unauthorized}

      true ->
        attrs = normalize_attrs(attrs)

        fresh
        |> Comment.update_changeset(attrs)
        |> Repo.update()
    end
  end

  @doc """
  Soft-deletes a comment, preserving the row for reply-tree integrity.

  The author may delete their own comment. Moderators and admins may delete
  any comment. The `deleted_at` timestamp and `deleted_by_id` are set
  atomically.
  """
  @spec soft_delete_comment(Comment.t(), User.t()) ::
          {:ok, Comment.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, :unauthorized | :already_deleted}
  def soft_delete_comment(%Comment{id: id}, %User{} = actor) do
    fresh = Repo.get!(Comment, id)

    cond do
      Comment.deleted?(fresh) ->
        {:error, :already_deleted}

      not can_delete?(fresh, actor) ->
        {:error, :unauthorized}

      true ->
        fresh
        |> Comment.soft_delete_changeset(%{
          deleted_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
          deleted_by_id: actor.id
        })
        |> Repo.update()
    end
  end

  @doc """
  Hard-deletes a comment. Only moderators/admins should call this; it
  respects the RESTRICT FK on `parent_id` so a parent with replies cannot be
  removed without handling children first.
  """
  @spec delete_comment(Comment.t(), User.t()) ::
          {:ok, Comment.t()} | {:error, Ecto.Changeset.t()} | {:error, :unauthorized}
  def delete_comment(%Comment{} = comment, %User{} = actor) do
    if moderator?(actor) do
      Repo.delete(comment)
    else
      {:error, :unauthorized}
    end
  end

  # Votes

  @doc """
  Casts or changes a user's vote on a comment.

  `vote` must be `1` (upvote) or `-1` (downvote). The operation is
  transactional: the comment row is locked, the existing vote is locked, and
  `comments.vote_score` is adjusted by the delta so concurrent voters never
  lose counts. Soft-deleted comments cannot be voted on.

  Returns `{:ok, %Vote{}}` or `{:error, changeset}` / `{:error, :deleted}`.
  """
  @spec vote_comment(User.t(), Comment.t(), integer()) ::
          {:ok, Vote.t()} | {:error, Ecto.Changeset.t()} | {:error, :deleted}
  def vote_comment(%User{id: user_id}, %Comment{} = comment, vote)
      when vote in [-1, 1] do
    if Comment.deleted?(comment) do
      {:error, :deleted}
    else
      transactional_vote(user_id, comment, vote)
    end
  end

  def vote_comment(_user, _comment, _vote), do: {:error, invalid_vote_changeset()}

  defp transactional_vote(user_id, comment, vote) do
    in_transaction(fn ->
      locked_comment = lock_comment!(comment.id)
      verify_not_deleted_and_vote(user_id, locked_comment, vote)
    end)
    |> case do
      {:error, :deleted} -> {:error, :deleted}
      other -> other
    end
  end

  defp verify_not_deleted_and_vote(user_id, locked_comment, vote) do
    if Comment.deleted?(locked_comment) do
      Repo.rollback(:deleted)
    else
      do_vote(user_id, locked_comment, vote)
    end
  end

  @doc """
  Removes a user's vote from a comment, adjusting `vote_score`.

  Idempotent: removing a non-existent vote is `:ok`.
  """
  @spec unvote_comment(User.t(), Comment.t()) ::
          :ok | {:error, term()}
  def unvote_comment(%User{id: user_id}, %Comment{} = comment) do
    in_transaction(fn ->
      locked_comment = lock_comment!(comment.id)

      case find_vote_for_update(user_id, locked_comment.id) do
        nil ->
          :ok

        %Vote{vote: previous} = vote ->
          Repo.delete!(vote)
          adjust_vote_score(locked_comment, -previous)
          :ok
      end
    end)
  end

  @spec get_vote(User.t(), Comment.t()) :: Vote.t() | nil
  def get_vote(%User{id: user_id}, %Comment{id: comment_id}) do
    Query.get_vote(user_id, comment_id)
  end

  @spec list_votes(Comment.t()) :: [Vote.t()]
  def list_votes(%Comment{id: comment_id}), do: Query.list_votes(comment_id)

  # Attachments

  @doc """
  Creates a comment attachment with strict validation.

  The actor must own the target comment (or be a moderator). Validates
  allowlisted content types, max 5 MiB, and safe storage keys.
  """
  @spec create_attachment(map(), User.t()) ::
          {:ok, Attachment.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, :unauthorized | :comment_not_found | :comment_deleted}
  def create_attachment(attrs, %User{} = actor) when is_map(attrs) do
    attrs = normalize_attrs(attrs)
    comment_id = Map.get(attrs, :comment_id)

    case get_comment(comment_id) do
      nil ->
        {:error, :comment_not_found}

      %Comment{} = comment ->
        cond do
          Comment.deleted?(comment) ->
            {:error, :comment_deleted}

          not can_attach?(comment, actor) ->
            {:error, :unauthorized}

          true ->
            enriched =
              attrs
              |> Map.put(:user_id, actor.id)
              |> Map.put(:comment_id, comment.id)

            %Attachment{}
            |> Attachment.changeset(enriched)
            |> Repo.insert()
        end
    end
  end

  # Backwards-compatible single-arity version for tests that insert directly.
  @spec create_attachment(map()) :: {:ok, Attachment.t()} | {:error, Ecto.Changeset.t()}
  def create_attachment(attrs) when is_map(attrs) do
    %Attachment{} |> Attachment.changeset(normalize_attrs(attrs)) |> Repo.insert()
  end

  @spec list_attachments(Comment.t()) :: [Attachment.t()]
  def list_attachments(%Comment{id: comment_id} = comment) do
    if Comment.deleted?(comment) do
      []
    else
      Query.list_attachments(comment_id)
    end
  end

  @spec get_attachment(integer()) :: Attachment.t() | nil
  def get_attachment(id) when is_integer(id), do: Repo.get(Attachment, id)

  # Markdown helper

  @doc "Renders markdown to safe HTML (exposed for testing and LiveView helpers)."
  @spec render_markdown(String.t() | nil) :: String.t()
  def render_markdown(markdown), do: Markdown.render(markdown)

  # Private

  defp validate_parent(attrs) do
    parent_id = Map.get(attrs, :parent_id)

    if is_nil(parent_id) do
      :ok
    else
      check_parent(parent_id, attrs)
    end
  end

  defp check_parent(parent_id, attrs) do
    case Repo.get(Comment, parent_id) do
      nil -> {:error, :parent_not_found}
      %Comment{deleted_at: deleted_at} when not is_nil(deleted_at) -> {:error, :parent_deleted}
      %Comment{} = parent -> validate_parent_target(parent, attrs)
    end
  end

  defp validate_parent_target(parent, attrs) do
    series_id = Map.get(attrs, :series_id)
    chapter_id = Map.get(attrs, :chapter_id)

    cond do
      not is_nil(parent.series_id) and parent.series_id != series_id ->
        {:error, :parent_target_mismatch}

      not is_nil(parent.chapter_id) and parent.chapter_id != chapter_id ->
        {:error, :parent_target_mismatch}

      true ->
        :ok
    end
  end

  defp do_vote(user_id, %Comment{} = comment, vote) do
    case find_vote_for_update(user_id, comment.id) do
      nil ->
        create_vote_row(user_id, comment, vote)

      %Vote{vote: ^vote} = existing ->
        {:ok, existing}

      %Vote{vote: previous} = existing ->
        update_vote_row(existing, vote, previous, comment)
    end
  end

  defp create_vote_row(user_id, %Comment{} = comment, vote) do
    changeset = Vote.changeset(%Vote{}, %{user_id: user_id, comment_id: comment.id, vote: vote})

    case Repo.insert(changeset) do
      {:ok, inserted} ->
        adjust_vote_score(comment, vote)
        maybe_notify_upvote(comment, user_id, vote)
        {:ok, inserted}

      {:error, changeset} ->
        Repo.rollback(changeset)
    end
  end

  defp update_vote_row(existing, vote, previous, %Comment{} = comment) do
    case existing |> Vote.changeset(%{vote: vote}) |> Repo.update() do
      {:ok, updated} ->
        adjust_vote_score(comment, vote - previous)

        if vote == 1 and previous != 1 do
          maybe_notify_upvote(comment, updated.user_id, vote)
        end

        {:ok, updated}

      {:error, changeset} ->
        Repo.rollback(changeset)
    end
  end

  defp maybe_notify_reply(%Comment{parent_id: nil}), do: :ok

  defp maybe_notify_reply(%Comment{parent_id: parent_id, user_id: actor_id, id: comment_id}) do
    case Repo.get(Comment, parent_id) do
      %Comment{user_id: recipient_id}
      when not is_nil(recipient_id) and recipient_id != actor_id ->
        Notifications.create_notification(%{
          recipient_id: recipient_id,
          actor_id: actor_id,
          comment_id: comment_id,
          action: "comment_reply"
        })

      _ ->
        :ok
    end
  end

  defp maybe_notify_upvote(%Comment{user_id: recipient_id, id: comment_id}, actor_id, 1)
       when not is_nil(recipient_id) and recipient_id != actor_id do
    Notifications.create_notification(%{
      recipient_id: recipient_id,
      actor_id: actor_id,
      comment_id: comment_id,
      action: "comment_upvote"
    })
  rescue
    _ -> :ok
  end

  defp maybe_notify_upvote(_comment, _actor_id, _vote), do: :ok

  defp lock_comment!(id) do
    Repo.one!(from(c in Comment, where: c.id == ^id, lock: "FOR UPDATE"))
  end

  defp find_vote_for_update(user_id, comment_id) do
    from(v in Vote,
      where: v.user_id == ^user_id and v.comment_id == ^comment_id,
      lock: "FOR UPDATE"
    )
    |> Repo.one()
  end

  defp adjust_vote_score(%Comment{id: comment_id}, delta) when is_integer(delta) do
    from(c in Comment, where: c.id == ^comment_id)
    |> Repo.update_all(inc: [vote_score: delta])
  end

  defp invalid_vote_changeset do
    %Vote{}
    |> Vote.changeset(%{vote: 0})
    |> Map.put(:valid?, false)
  end

  defp can_delete?(%Comment{user_id: author_id}, %User{id: actor_id} = actor) do
    author_id == actor_id or moderator?(actor)
  end

  defp can_attach?(%Comment{user_id: author_id}, %User{id: actor_id} = actor) do
    author_id == actor_id or moderator?(actor)
  end

  defp moderator?(actor) do
    case actor do
      %User{role: %{name: name}} when name in @moderator_roles ->
        true

      %User{} = user ->
        case Repo.preload(user, :role) do
          %{role: %{name: name}} when name in @moderator_roles -> true
          _ -> false
        end

      _ ->
        false
    end
  end

  defp normalize_attrs(attrs) when is_map(attrs) do
    Map.new(attrs, fn
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
      {k, v} -> {k, v}
    end)
  rescue
    ArgumentError -> Map.new(attrs)
  end

  defp in_transaction(fun) do
    case Repo.transaction(fun) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end
end
