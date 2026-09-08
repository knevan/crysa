defmodule Crysa.Notifications do
  @moduledoc """
  Notifications context for user-facing activity events.

  Two domain share one table:

    * Comment activity (`comment_reply`, `comment_upvote`,
      `comment_downvote`) references exactly one comment.
    * Series updates (`series_chapter`) references exactly one series and
      chapter and is fanned out to that series' bookmarkers.

  Target integrity is enforced by the `notifications_target_check`
  database constraint; series fan-out idempotency by the partial unique
  index `notifications_series_dedupe_index`.
  """

  import Ecto.Query

  alias Crysa.Library.Bookmark
  alias Crysa.Notifications.Notification
  alias Crysa.Repo

  @actions ~w(comment_reply comment_upvote comment_downvote series_chapter)
  @comment_actions ~w(comment_reply comment_upvote comment_downvote)
  @series_actions ~w(series_chapter)
  @tabs ~w(comment series)

  # One bulk row carries 8 columns; 500 rows stay far below the
  # 65_535 adapter parameter limit while keeping transactions short.
  @fan_out_chunk_size 500
  @default_page_size 20
  @max_page_size 50

  @type tab :: String.t()
  @type notification_json :: map()

  @spec actions() :: [String.t()]
  def actions, do: @actions

  @spec tabs() :: [tab()]
  def tabs, do: @tabs

  @spec create_notification(map()) :: {:ok, Notification.t()} | {:error, Ecto.Changeset.t()}
  def create_notification(attrs),
    do: %Notification{} |> Notification.changeset(attrs) |> Repo.insert()

  @doc """
  Lists a recipient's notifications for one tab, newest first.

  Keyset pagination on `id` keeps page fetches stable while new rows
  arrive: pass `cursor` as the last seen id to load older entries.
  Numbered pages use `offset` instead (`(page - 1) * limit`); new
  arrivals may shift offset windows by a row, which the notification
  center accepts in exchange for direct page jumps.
  With `unread_only: true` only unread rows are returned (dropdown
  surfaces clear read rows instead of greying them out).
  Returns `{items, has_more}` where items are JSON-safe maps.
  """
  @spec list_notifications(integer(), tab(), keyword()) ::
          {:ok, {[notification_json()], boolean()}} | {:error, :invalid_tab}
  def list_notifications(recipient_id, tab, opts \\ [])
      when is_integer(recipient_id) and is_binary(tab) and is_list(opts) do
    with {:ok, actions} <- tab_actions(tab) do
      limit = clamp_page_size(Keyword.get(opts, :limit, @default_page_size))
      cursor = Keyword.get(opts, :cursor)
      offset = clamp_offset(Keyword.get(opts, :offset, 0))
      unread_only? = Keyword.get(opts, :unread_only, false) == true

      base =
        from(n in Notification,
          where: n.recipient_id == ^recipient_id and n.action in ^actions,
          order_by: [desc: n.id],
          limit: ^(limit + 1),
          offset: ^offset,
          select: n.id
        )

      ids =
        base
        |> maybe_filter_unread(unread_only?)
        |> maybe_apply_cursor(cursor)
        |> Repo.all()

      {page_ids, rest} = Enum.split(ids, limit)
      {:ok, {load_notification_json(page_ids), rest != []}}
    end
  end

  @doc """
  Counts a recipient's notifications for one tab, newest first.

  Backs numbered pagination in the notification center; accepts the
  same `unread_only` filter as `list_notifications/3` so totals match
  the listed rows.
  """
  @spec count_notifications(integer(), tab(), keyword()) ::
          non_neg_integer() | {:error, :invalid_tab}
  def count_notifications(recipient_id, tab, opts \\ [])
      when is_integer(recipient_id) and is_binary(tab) and is_list(opts) do
    with {:ok, actions} <- tab_actions(tab) do
      unread_only? = Keyword.get(opts, :unread_only, false) == true

      from(n in Notification,
        where: n.recipient_id == ^recipient_id and n.action in ^actions,
        select: n.id
      )
      |> maybe_filter_unread(unread_only?)
      |> Repo.aggregate(:count, :id)
    end
  end

  @doc """
  Counts unread notifications for a recipient, optionally scoped to one tab.
  """
  @spec unread_count(integer()) :: non_neg_integer()
  def unread_count(recipient_id) when is_integer(recipient_id) do
    Repo.aggregate(unread_base(recipient_id), :count, :id)
  end

  @spec unread_count(integer(), tab()) :: non_neg_integer() | {:error, :invalid_tab}
  def unread_count(recipient_id, tab) when is_integer(recipient_id) and is_binary(tab) do
    with {:ok, actions} <- tab_actions(tab) do
      unread_base(recipient_id)
      |> where([n], n.action in ^actions)
      |> Repo.aggregate(:count, :id)
    end
  end

  @doc """
  Counts unread notifications per tab for the panel badges.
  """
  @spec unread_counts(integer()) :: %{comment: non_neg_integer(), series: non_neg_integer()}
  def unread_counts(recipient_id) when is_integer(recipient_id) do
    %{
      comment: unread_count(recipient_id, "comment"),
      series: unread_count(recipient_id, "series")
    }
  end

  @doc """
  Marks notifications read for a recipient.

  Scopes:

    * `%{scope: "item", id: id}` — one notification (swipe-to-read).
    * `%{scope: "tab", tab: tab}` — all unread rows in one tab.

  Never touches other recipients' rows; unknown ids report `:not_found`
  instead of leaking row existence across users.
  """
  @spec mark_as_read(integer(), map()) ::
          {:ok, non_neg_integer()}
          | {:error, :invalid_tab | :not_found | :invalid_scope}
  def mark_as_read(recipient_id, %{scope: "item", id: id})
      when is_integer(recipient_id) and is_integer(id) do
    {count, _} =
      unread_base(recipient_id)
      |> where([n], n.id == ^id)
      |> Repo.update_all(set: [read_at: DateTime.utc_now()])

    if count == 0, do: {:error, :not_found}, else: {:ok, count}
  end

  def mark_as_read(recipient_id, %{scope: "tab", tab: tab})
      when is_integer(recipient_id) and is_binary(tab) do
    with {:ok, actions} <- tab_actions(tab) do
      {count, _} =
        unread_base(recipient_id)
        |> where([n], n.action in ^actions)
        |> Repo.update_all(set: [read_at: DateTime.utc_now()])

      {:ok, count}
    end
  end

  def mark_as_read(_recipient_id, _params), do: {:error, :invalid_scope}

  @doc """
  Fans out a `series_chapter` notification to every bookmarker of the
  series. Idempotent: worker retries insert zero new rows through the
  partial unique index. Returns the number of newly inserted rows.

  Each newly notified recipient also receives a realtime push on
  `notifications:<user_id>`; retried (already-inserted) rows are not
  re-broadcast. Chapter publishes are infrequent, so one message per
  follower is proportional; revisit if a series ever grows to
  notification-spam scale.

  Call only for chapters that are already readable (`available`); the
  reader renders no status gate of its own.
  """
  @spec notify_series_chapter(integer(), integer()) :: {:ok, non_neg_integer()}
  def notify_series_chapter(series_id, chapter_id)
      when is_integer(series_id) and is_integer(chapter_id) do
    now = DateTime.utc_now()

    follower_ids =
      Repo.all(from(b in Bookmark, where: b.series_id == ^series_id, select: b.user_id))

    {inserted_count, inserted_rows} =
      follower_ids
      |> Enum.chunk_every(@fan_out_chunk_size)
      |> Enum.reduce({0, []}, fn chunk, {count_acc, rows_acc} ->
        rows =
          Enum.map(chunk, fn user_id ->
            %{
              recipient_id: user_id,
              actor_id: nil,
              comment_id: nil,
              series_id: series_id,
              chapter_id: chapter_id,
              action: "series_chapter",
              read_at: nil,
              inserted_at: now,
              updated_at: now
            }
          end)

        {count, inserted} =
          Repo.insert_all(Notification, rows,
            on_conflict: :nothing,
            conflict_target:
              {:unsafe_fragment,
               "(recipient_id, series_id, chapter_id) WHERE action = 'series_chapter'"},
            returning: [:id, :recipient_id]
          )

        {count_acc + count, inserted ++ rows_acc}
      end)

    Enum.each(inserted_rows, fn %{id: id, recipient_id: recipient_id} ->
      broadcast_to_recipient(recipient_id, %{
        id: id,
        action: "series_chapter",
        comment_id: nil,
        series_id: series_id,
        chapter_id: chapter_id
      })
    end)

    {:ok, inserted_count}
  end

  @doc """
  Broadcasts a notification to its recipient's realtime topic.
  Subscribers receive `{:notification_created, payload}` where payload
  carries the action plus the referenced entity ids.
  """
  @spec broadcast_notification(Notification.t()) :: :ok
  def broadcast_notification(%Notification{} = notification) do
    broadcast_to_recipient(notification.recipient_id, broadcast_payload(notification))
  end

  @doc """
  Broadcasts a prebuilt payload to one recipient's realtime topic.
  """
  @spec broadcast_to_recipient(integer(), map()) :: :ok
  def broadcast_to_recipient(recipient_id, payload) when is_integer(recipient_id) do
    Phoenix.PubSub.broadcast(
      Crysa.PubSub,
      "notifications:#{recipient_id}",
      {:notification_created, payload}
    )

    :ok
  end

  @doc """
  Small payload for realtime pushes; clients refetch authoritative rows.
  """
  @spec broadcast_payload(Notification.t()) :: map()
  def broadcast_payload(%Notification{} = notification) do
    %{
      id: notification.id,
      action: notification.action,
      comment_id: notification.comment_id,
      series_id: notification.series_id,
      chapter_id: notification.chapter_id
    }
  end

  # -- Private ----------------------------------------------------------

  defp tab_actions("comment"), do: {:ok, @comment_actions}
  defp tab_actions("series"), do: {:ok, @series_actions}
  defp tab_actions(_), do: {:error, :invalid_tab}

  defp unread_base(recipient_id) do
    from(n in Notification,
      where: n.recipient_id == ^recipient_id and is_nil(n.read_at)
    )
  end

  defp maybe_apply_cursor(query, nil), do: query

  defp maybe_apply_cursor(query, cursor) when is_integer(cursor),
    do: where(query, [n], n.id < ^cursor)

  defp maybe_apply_cursor(query, _), do: query

  defp maybe_filter_unread(query, false), do: query
  defp maybe_filter_unread(query, true), do: where(query, [n], is_nil(n.read_at))

  defp clamp_page_size(size) when is_integer(size) and size > 0, do: min(size, @max_page_size)
  defp clamp_page_size(_), do: @default_page_size

  defp clamp_offset(offset) when is_integer(offset) and offset >= 0, do: offset
  defp clamp_offset(_), do: 0

  defp load_notification_json([]), do: []

  defp load_notification_json(ids) do
    from(n in Notification,
      where: n.id in ^ids,
      order_by: [desc: n.id],
      preload: [:actor, :series, :chapter, comment: [:series, chapter: :series]]
    )
    |> Repo.all()
    |> Enum.map(&to_notification_json/1)
  end

  defp to_notification_json(%Notification{} = n) do
    %{
      id: n.id,
      action: n.action,
      read_at: n.read_at && DateTime.to_iso8601(n.read_at),
      inserted_at: DateTime.to_iso8601(n.inserted_at),
      actor: actor_json(n.actor),
      series: series_json(n.series),
      chapter: chapter_json(n.chapter),
      comment: comment_json(n.comment)
    }
  end

  defp actor_json(nil), do: nil
  defp actor_json(actor), do: %{id: actor.id, username: actor.username}

  defp series_json(nil), do: nil

  defp series_json(series),
    do: %{id: series.id, title: series.title, slug: series.slug, cover_url: series.cover_url}

  defp chapter_json(nil), do: nil

  defp chapter_json(chapter),
    do: %{
      id: chapter.id,
      chapter_key: chapter.chapter_key,
      display_number: chapter.display_number,
      title: chapter.title
    }

  defp comment_json(nil), do: nil

  defp comment_json(comment) do
    series_slug =
      (comment.series && comment.series.slug) ||
        (comment.chapter && comment.chapter.series && comment.chapter.series.slug)

    %{
      id: comment.id,
      excerpt: excerpt(comment.body_markdown),
      series_id: comment.series_id,
      series_slug: series_slug,
      chapter_id: comment.chapter_id
    }
  end

  defp excerpt(nil), do: ""
  defp excerpt(body), do: body |> String.slice(0, 120)
end
