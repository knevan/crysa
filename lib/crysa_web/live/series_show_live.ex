defmodule CrysaWeb.Live.SeriesShowLive do
  @moduledoc """
  Series detail LiveView — mobile-first UI from `ui/pencil-new.pen` "Series Page — Mobile".

  Thin orchestration over `Crysa.Catalog`, `Crysa.Library` and `Crysa.Comments`.
  All business rules, validation and pagination live in the contexts; this module
  only maps server rows to client props and handles LiveVue island events.

  Features:
    * SSR-friendly via `v-ssr={true}` (public content must be crawler-visible).
    * Optimistic bookmark / rating handled client-side, reconciled via assigns.
    * Chapter list: search (display_number/title/chapter_key), sort (newest/oldest),
      bounded pagination.
    * Comments: composer, sorting (newest/oldest/most_voted), bounded pagination,
      voting.
    * View display: subscribes to `series:<id>` for coalesced view count
      updates. Views are counted on chapter reads, not on this page.

  Notes on mobile design:
    * The component is centered `max-w-[390px]` on mobile and expands to
      `max-w-[680px]` on tablet/desktop, keeping the pencil card radius/shadow
      while staying readable on larger viewports.
    * All colours use the shadcn tokens in `assets/css/app.css` so HEEX chrome
      and the Vue island are pixel-identical (see `AGENTS.md` / `app.css`).
  """

  use CrysaWeb, :live_view

  alias Crysa.Catalog
  alias Crysa.Comments
  alias Crysa.Library

  @chapter_page_size 20
  @comment_page_size 20

  on_mount {CrysaWeb.UserAuth, :mount_current_user}

  @impl true
  def render(assigns) do
    ~H"""
    <div :if={@not_found} class="mx-auto max-w-170 px-4 py-16 text-center">
      <h1 class="text-2xl font-bold">Series not found</h1>
      <p class="mt-2 text-sm text-muted-foreground">The series you are looking for does not exist.</p>
      <a
        href={~p"/series"}
        class="mt-6 inline-flex h-9 items-center rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground"
      >Browse series</a>
    </div>

    <div :if={!@not_found}>
      <.vue
        v-component="SeriesPage"
        v-ssr={true}
        series={@series}
        authors={@authors}
        categories={@categories}
        stats={@stats}
        coverUrl={@cover_url}
        description={@description}
        ratingSummary={@rating_summary}
        ratingDistribution={@rating_distribution}
        bookmarked={@bookmarked}
        userRating={@user_rating}
        currentUser={@current_user_json}
        latestChapter={@latest_chapter}
        chapters={@chapters}
        chapterPagination={@chapter_pagination}
        chapterQuery={@chapter_query}
        chapterSort={@chapter_sort}
        comments={@comments}
        commentTree={@comment_tree}
        commentPagination={@comment_pagination}
        commentSort={@comment_sort}
        commentCount={@comment_count}
        threadId={@thread_id}
        isThreadView={@is_thread_view}
      />
    </div>
    """
  end

  @impl true
  def mount(%{"slug" => slug} = params, _session, socket) do
    case Catalog.get_series_by_slug(slug) do
      nil ->
        {:ok, assign(socket, not_found: true, slug: slug)}

      series ->
        current_user = socket.assigns[:current_user]

        if connected?(socket) do
          Phoenix.PubSub.subscribe(Crysa.PubSub, "series:#{series.id}")
        end

        chapter_query = parse_q(params, "q")
        chapter_sort = parse_chapter_sort(params)
        chapter_page = parse_page(params, "page")

        {chapters, chapter_pagination} =
          list_public_chapters(series.id, %{
            "q" => chapter_query,
            "sort" => chapter_sort,
            "page" => chapter_page,
            "page_size" => @chapter_page_size
          })

        latest_chapter = Catalog.get_latest_chapter(series.id)

        comment_sort = parse_comment_sort(params)
        comment_page = parse_page(params, "comment_page")
        thread_id = parse_thread_id(params["thread"])

        {comment_tree_nodes, comment_pagination, thread_view?} =
          load_comment_tree(series, thread_id, %{
            "sort" => comment_sort,
            "page" => comment_page,
            "page_size" => @comment_page_size
          })

        comment_tree = Enum.map(comment_tree_nodes, &to_comment_node_json/1)

        # Keep flat `comments` for backwards compat (flattened tree) and for tests that may inspect it
        flat_comments = flatten_comment_tree(comment_tree_nodes)
        vote_counts = Comments.vote_counts_for_comment_ids(Enum.map(flat_comments, & &1.id))

        comments =
          Enum.map(
            flat_comments,
            &to_comment_json(&1, Map.get(vote_counts, &1.id, %{up: 0, down: 0}))
          )

        comment_count = Comments.count_comments_for_series(series.id)
        rating_summary = Library.rating_summary(series)
        rating_distribution = Library.rating_distribution(series)
        {bookmarked, user_rating} = user_library_state(current_user, series)

        {:ok,
         assign(socket,
           not_found: false,
           slug: slug,
           series: to_series_json(series),
           raw_series: series,
           authors: Enum.map(series.authors || [], &to_author_json/1),
           categories: Enum.map(series.categories || [], &to_category_json/1),
           stats: to_stats_json(series),
           cover_url: series.cover_url,
           description: series.description,
           rating_summary: rating_summary_to_json(rating_summary),
           rating_distribution: rating_distribution,
           bookmarked: bookmarked,
           user_rating: user_rating,
           current_user_json: to_user_json(current_user),
           latest_chapter: to_chapter_json(latest_chapter),
           chapters: Enum.map(chapters, &to_chapter_json/1),
           chapter_pagination: to_pagination_json(chapter_pagination),
           chapter_query: chapter_query || "",
           chapter_sort: chapter_sort,
           comments: comments,
           comment_tree: comment_tree,
           comment_pagination: to_pagination_json(comment_pagination),
           comment_sort: comment_sort,
           comment_count: comment_count,
           thread_id: thread_id,
           is_thread_view: thread_view?,
           chapter_page: chapter_pagination.page,
           comment_page: comment_pagination.page
         )}
    end
  end

  # Fallback mount when slug missing (should not happen via router, but keep safe)
  def mount(_params, _session, socket), do: {:ok, assign(socket, not_found: true)}

  @impl true
  def handle_params(params, _url, socket) do
    if socket.assigns[:not_found] do
      {:noreply, socket}
    else
      series = socket.assigns.raw_series

      # Only reload chapters if a relevant param is present in the URL
      needs_chapter_reload =
        Map.has_key?(params, "q") or Map.has_key?(params, "sort") or Map.has_key?(params, "page") or
          Map.has_key?(params, "chapter_q") or Map.has_key?(params, "chapter_sort")

      socket =
        if needs_chapter_reload do
          q = parse_q(params, "q") || parse_q(params, "chapter_q") || socket.assigns.chapter_query

          sort =
            parse_chapter_sort_opt(params, "sort") ||
              parse_chapter_sort_opt(params, "chapter_sort") || socket.assigns.chapter_sort

          page =
            cond do
              Map.has_key?(params, "page") -> parse_page(params, "page")
              Map.has_key?(params, "chapter_page") -> parse_page(params, "chapter_page")
              true -> socket.assigns.chapter_page
            end

          {chapters, pagination} =
            list_public_chapters(series.id, %{
              "q" => q,
              "sort" => sort,
              "page" => page,
              "page_size" => @chapter_page_size
            })

          assign(socket,
            chapters: Enum.map(chapters, &to_chapter_json/1),
            chapter_pagination: to_pagination_json(pagination),
            chapter_query: q || "",
            chapter_sort: sort,
            chapter_page: pagination.page
          )
        else
          socket
        end

      new_thread_id = parse_thread_id(params["thread"])
      old_thread_id = socket.assigns[:thread_id]

      needs_comment_reload =
        Map.has_key?(params, "comment_sort") or Map.has_key?(params, "comment_page") or
          Map.has_key?(params, "thread") or new_thread_id != old_thread_id

      socket =
        if needs_comment_reload do
          sort =
            parse_comment_sort_opt(params, "comment_sort") ||
              parse_comment_sort_opt(params, "sort") || socket.assigns.comment_sort

          page =
            if Map.has_key?(params, "comment_page"),
              do: parse_page(params, "comment_page"),
              else: socket.assigns.comment_page

          thread_id = new_thread_id

          {tree_nodes, pagination, thread_view?} =
            load_comment_tree(series, thread_id, %{
              "sort" => sort,
              "page" => page,
              "page_size" => @comment_page_size
            })

          tree = Enum.map(tree_nodes, &to_comment_node_json/1)
          flat = flatten_comment_tree(tree_nodes)
          vote_counts = Comments.vote_counts_for_comment_ids(Enum.map(flat, & &1.id))

          assign(socket,
            comments:
              Enum.map(flat, &to_comment_json(&1, Map.get(vote_counts, &1.id, %{up: 0, down: 0}))),
            comment_tree: tree,
            comment_pagination: to_pagination_json(pagination),
            comment_sort: sort,
            comment_page: pagination.page,
            thread_id: thread_id,
            is_thread_view: thread_view?
          )
        else
          socket
        end

      {:noreply, socket}
    end
  end

  # Bookmark

  @impl true
  def handle_event("toggle_bookmark", _params, socket) do
    current_user = socket.assigns[:current_user]
    series = socket.assigns.raw_series

    if is_nil(current_user) do
      {:noreply, put_flash(socket, :error, "Please sign in to bookmark.")}
    else
      # Optimistic toggle — actual assign updated from DB result
      result =
        if socket.assigns.bookmarked do
          Library.unbookmark_series(current_user, series)
        else
          Library.bookmark_series(current_user, series)
        end

      case result do
        :ok ->
          # unbookmark returns :ok
          updated = reload_series(series.id)
          {bookmarked, _} = user_library_state(current_user, updated)

          {:noreply,
           assign(socket,
             bookmarked: bookmarked,
             series: to_series_json(updated),
             raw_series: updated,
             stats: to_stats_json(updated)
           )}

        {:ok, _bookmark} ->
          updated = reload_series(series.id)
          {bookmarked, _} = user_library_state(current_user, updated)

          {:noreply,
           assign(socket,
             bookmarked: bookmarked,
             series: to_series_json(updated),
             raw_series: updated,
             stats: to_stats_json(updated)
           )}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, "Could not update bookmark. Please try again.")}
      end
    end
  end

  def handle_event("rate_series", %{"rating" => rating_param}, socket) do
    current_user = socket.assigns[:current_user]
    series = socket.assigns.raw_series

    if is_nil(current_user) do
      {:noreply, put_flash(socket, :error, "Please sign in to rate.")}
    else
      try do
        with {rating, ""} <- Float.parse(to_string(rating_param)),
             true <- rating >= 1 and rating <= 5 and Float.round(rating * 2) == rating * 2 do
          case Library.rate_series(current_user, series, rating) do
            {:ok, _change} ->
              updated = reload_series(series.id)
              {_bookmarked, _user_rating} = user_library_state(current_user, updated)
              summary = Library.rating_summary(updated)
              distribution = Library.rating_distribution(updated)

              {:noreply,
               assign(socket,
                 user_rating: rating,
                 series: to_series_json(updated),
                 raw_series: updated,
                 stats: to_stats_json(updated),
                 rating_summary: rating_summary_to_json(summary),
                 rating_distribution: distribution
               )}

            {:error, _cs} ->
              {:noreply, put_flash(socket, :error, "Invalid rating.")}
          end
        else
          _ ->
            {:noreply, put_flash(socket, :error, "Rating must be between 1 and 5 in 0.5 steps.")}
        end
      rescue
        e ->
          require Logger

          Logger.error("rate_series crashed: #{inspect(e)}",
            error: inspect(e),
            series_id: series.id
          )

          {:noreply, put_flash(socket, :error, "Could not save rating. Please try again.")}
      end
    end
  end

  def handle_event("unrate_series", _params, socket) do
    current_user = socket.assigns[:current_user]
    series = socket.assigns.raw_series

    if is_nil(current_user) do
      {:noreply, put_flash(socket, :error, "Please sign in.")}
    else
      case Library.unrate_series(current_user, series) do
        :ok ->
          updated = reload_series(series.id)
          {_bookmarked, user_rating} = user_library_state(current_user, updated)
          summary = Library.rating_summary(updated)
          distribution = Library.rating_distribution(updated)

          {:noreply,
           assign(socket,
             user_rating: user_rating,
             series: to_series_json(updated),
             raw_series: updated,
             stats: to_stats_json(updated),
             rating_summary: rating_summary_to_json(summary),
             rating_distribution: distribution
           )}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Could not remove rating.")}
      end
    end
  end

  # Chapters

  def handle_event("search_chapters", %{"q" => q}, socket) do
    series = socket.assigns.raw_series
    query = String.trim(to_string(q || "")) |> String.slice(0, 100)
    sort = socket.assigns.chapter_sort

    {chapters, pagination} =
      list_public_chapters(series.id, %{
        "q" => query,
        "sort" => sort,
        "page" => 1,
        "page_size" => @chapter_page_size
      })

    {:noreply,
     assign(socket,
       chapters: Enum.map(chapters, &to_chapter_json/1),
       chapter_pagination: to_pagination_json(pagination),
       chapter_query: query,
       chapter_page: 1
     )}
  end

  def handle_event("sort_chapters", %{"sort" => sort}, socket) do
    series = socket.assigns.raw_series
    sort = if sort in ["newest", "oldest"], do: sort, else: "newest"
    q = socket.assigns.chapter_query

    {chapters, pagination} =
      list_public_chapters(series.id, %{
        "q" => q,
        "sort" => sort,
        "page" => 1,
        "page_size" => @chapter_page_size
      })

    {:noreply,
     assign(socket,
       chapters: Enum.map(chapters, &to_chapter_json/1),
       chapter_pagination: to_pagination_json(pagination),
       chapter_sort: sort,
       chapter_page: 1
     )}
  end

  def handle_event("chapter_page_change", %{"page" => page_param}, socket) do
    series = socket.assigns.raw_series
    page = parse_int(page_param, 1)
    q = socket.assigns.chapter_query
    sort = socket.assigns.chapter_sort

    {chapters, pagination} =
      list_public_chapters(series.id, %{
        "q" => q,
        "sort" => sort,
        "page" => page,
        "page_size" => @chapter_page_size
      })

    {:noreply,
     assign(socket,
       chapters: Enum.map(chapters, &to_chapter_json/1),
       chapter_pagination: to_pagination_json(pagination),
       chapter_page: pagination.page
     )}
  end

  def handle_event("chapter_page_size_change", %{"page_size" => size_param}, socket) do
    # Keep page size bounded to @chapter_page_size; admin uses different sizes, but series page is fixed.
    # Accept only 20/50 for flexibility, clamp otherwise.
    _ = size_param
    {:noreply, socket}
  end

  # Comments

  def handle_event("create_comment", %{"body" => body} = params, socket) do
    current_user = socket.assigns[:current_user]
    series = socket.assigns.raw_series

    if is_nil(current_user) do
      {:noreply, put_flash(socket, :error, "Please sign in to comment.")}
    else
      body = String.trim(to_string(body || ""))

      cond do
        body == "" ->
          {:noreply, put_flash(socket, :error, "Comment cannot be empty.")}

        String.length(body) > 10_000 ->
          {:noreply, put_flash(socket, :error, "Comment is too long (max 10,000).")}

        true ->
          parent_id = parse_int(params["parent_id"], nil)

          attrs = %{
            user_id: current_user.id,
            series_id: series.id,
            body_markdown: body,
            parent_id: parent_id
          }

          case Comments.create_comment(attrs) do
            {:ok, _comment} ->
              sort = socket.assigns.comment_sort
              thread_id = socket.assigns[:thread_id]

              {tree_nodes, pagination, _} =
                load_comment_tree(series, thread_id, %{
                  "sort" => sort,
                  "page" => 1,
                  "page_size" => @comment_page_size
                })

              tree = Enum.map(tree_nodes, &to_comment_node_json/1)
              flat = flatten_comment_tree(tree_nodes)
              vote_counts = Comments.vote_counts_for_comment_ids(Enum.map(flat, & &1.id))
              count = Comments.count_comments_for_series(series.id)

              {:noreply,
               assign(socket,
                 comments:
                   Enum.map(
                     flat,
                     &to_comment_json(&1, Map.get(vote_counts, &1.id, %{up: 0, down: 0}))
                   ),
                 comment_tree: tree,
                 comment_pagination: to_pagination_json(pagination),
                 comment_count: count,
                 comment_page: 1
               )}

            {:error, %Ecto.Changeset{} = cs} ->
              msg = extract_changeset_error(cs)
              {:noreply, put_flash(socket, :error, msg)}

            {:error, reason} when is_atom(reason) ->
              {:noreply, put_flash(socket, :error, humanize_comment_error(reason))}
          end
      end
    end
  end

  def handle_event("vote_comment", %{"id" => id_param, "vote" => vote_param}, socket) do
    current_user = socket.assigns[:current_user]

    if is_nil(current_user) do
      {:noreply, put_flash(socket, :error, "Please sign in to vote.")}
    else
      with {comment_id, ""} <- Integer.parse(to_string(id_param)),
           {vote, ""} <- Integer.parse(to_string(vote_param)),
           true <- vote in [-1, 1],
           comment when not is_nil(comment) <- Comments.get_comment(comment_id) do
        case Comments.vote_comment(current_user, comment, vote) do
          {:ok, _vote} ->
            series = socket.assigns.raw_series
            sort = socket.assigns.comment_sort
            page = socket.assigns.comment_page
            thread_id = socket.assigns[:thread_id]

            {tree_nodes, pagination, _} =
              load_comment_tree(series, thread_id, %{
                "sort" => sort,
                "page" => page,
                "page_size" => @comment_page_size
              })

            tree = Enum.map(tree_nodes, &to_comment_node_json/1)
            flat = flatten_comment_tree(tree_nodes)
            vote_counts = Comments.vote_counts_for_comment_ids(Enum.map(flat, & &1.id))

            {:noreply,
             assign(socket,
               comments:
                 Enum.map(
                   flat,
                   &to_comment_json(&1, Map.get(vote_counts, &1.id, %{up: 0, down: 0}))
                 ),
               comment_tree: tree,
               comment_pagination: to_pagination_json(pagination)
             )}

          {:error, :deleted} ->
            {:noreply, put_flash(socket, :error, "Cannot vote on deleted comment.")}

          {:error, _cs} ->
            {:noreply, put_flash(socket, :error, "Could not vote.")}
        end
      else
        _ -> {:noreply, put_flash(socket, :error, "Invalid vote.")}
      end
    end
  end

  def handle_event("unvote_comment", %{"id" => id_param}, socket) do
    current_user = socket.assigns[:current_user]

    if is_nil(current_user) do
      {:noreply, put_flash(socket, :error, "Please sign in.")}
    else
      with {comment_id, ""} <- Integer.parse(to_string(id_param)),
           comment when not is_nil(comment) <- Comments.get_comment(comment_id) do
        :ok = Comments.unvote_comment(current_user, comment)

        series = socket.assigns.raw_series
        sort = socket.assigns.comment_sort
        page = socket.assigns.comment_page
        thread_id = socket.assigns[:thread_id]

        {tree_nodes, pagination, _} =
          load_comment_tree(series, thread_id, %{
            "sort" => sort,
            "page" => page,
            "page_size" => @comment_page_size
          })

        tree = Enum.map(tree_nodes, &to_comment_node_json/1)
        flat = flatten_comment_tree(tree_nodes)
        vote_counts = Comments.vote_counts_for_comment_ids(Enum.map(flat, & &1.id))

        {:noreply,
         assign(socket,
           comments:
             Enum.map(flat, &to_comment_json(&1, Map.get(vote_counts, &1.id, %{up: 0, down: 0}))),
           comment_tree: tree,
           comment_pagination: to_pagination_json(pagination)
         )}
      else
        _ -> {:noreply, put_flash(socket, :error, "Invalid comment.")}
      end
    end
  end

  def handle_event("sort_comments", %{"sort" => sort}, socket) do
    series = socket.assigns.raw_series
    sort = if sort in ["newest", "oldest", "most_voted"], do: sort, else: "newest"
    thread_id = socket.assigns[:thread_id]

    # In thread view, sort is ignored (thread is chronological); still handle for full view
    {tree_nodes, pagination, _} =
      if thread_id do
        load_comment_tree(series, thread_id, %{})
      else
        load_comment_tree(series, nil, %{
          "sort" => sort,
          "page" => 1,
          "page_size" => @comment_page_size
        })
      end

    tree = Enum.map(tree_nodes, &to_comment_node_json/1)
    flat = flatten_comment_tree(tree_nodes)
    vote_counts = Comments.vote_counts_for_comment_ids(Enum.map(flat, & &1.id))

    {:noreply,
     assign(socket,
       comments:
         Enum.map(flat, &to_comment_json(&1, Map.get(vote_counts, &1.id, %{up: 0, down: 0}))),
       comment_tree: tree,
       comment_pagination: to_pagination_json(pagination),
       comment_sort: sort,
       comment_page: 1
     )}
  end

  def handle_event("comment_page_change", %{"page" => page_param}, socket) do
    series = socket.assigns.raw_series
    page = parse_int(page_param, 1)
    sort = socket.assigns.comment_sort
    thread_id = socket.assigns[:thread_id]

    # Thread view has single page; ignore pagination when in thread
    {tree_nodes, pagination, _} =
      if thread_id do
        load_comment_tree(series, thread_id, %{})
      else
        load_comment_tree(series, nil, %{
          "sort" => sort,
          "page" => page,
          "page_size" => @comment_page_size
        })
      end

    tree = Enum.map(tree_nodes, &to_comment_node_json/1)
    flat = flatten_comment_tree(tree_nodes)
    vote_counts = Comments.vote_counts_for_comment_ids(Enum.map(flat, & &1.id))

    {:noreply,
     assign(socket,
       comments:
         Enum.map(flat, &to_comment_json(&1, Map.get(vote_counts, &1.id, %{up: 0, down: 0}))),
       comment_tree: tree,
       comment_pagination: to_pagination_json(pagination),
       comment_page: pagination.page
     )}
  end

  def handle_event("preview_markdown", %{"markdown" => markdown}, socket) do
    # Server-side preview ensures 1:1 with persisted body_html (same sanitizer, spoiler ||, etc.)
    html = Crysa.Comments.Markdown.render(markdown || "")
    {:reply, %{html: html}, socket}
  end

  def handle_event("load_more_replies", %{"id" => id_param}, socket) do
    # "Continue this thread" → make parent before "More replies" the new head
    with {thread_id, ""} <- Integer.parse(to_string(id_param)),
         %Crysa.Comments.Comment{} = comment <- Crysa.Comments.get_comment(thread_id),
         true <- comment.series_id == socket.assigns.raw_series.id do
      {:noreply, push_patch(socket, to: ~p"/series/#{socket.assigns.slug}?thread=#{thread_id}")}
    else
      _ -> {:noreply, put_flash(socket, :error, "Thread not found.")}
    end
  end

  def handle_event("clear_thread", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/series/#{socket.assigns.slug}")}
  end

  @impl true
  def handle_info({:rating_updated, summary, dist, series_id}, socket) do
    # Only for current series; broadcast is for all viewers of this series
    if socket.assigns[:raw_series] && socket.assigns.raw_series.id == series_id do
      # Always update LiveView assigns; Vue will skip overwriting optimistic if pendingRatingVersion != 0
      updated_series = %{
        socket.assigns.raw_series
        | rating_count: summary.count,
          rating_sum: summary.sum
      }

      {:noreply,
       assign(socket,
         rating_summary: rating_summary_to_json(summary),
         rating_distribution: dist,
         stats: to_stats_json(updated_series),
         raw_series: updated_series,
         series: to_series_json(updated_series)
       )}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:view_count_updated, view_count, series_id}, socket) do
    if socket.assigns[:raw_series] && socket.assigns.raw_series.id == series_id do
      updated_series = %{socket.assigns.raw_series | view_count: view_count}

      {:noreply,
       assign(socket,
         raw_series: updated_series,
         series: to_series_json(updated_series),
         stats: to_stats_json(updated_series)
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # Thread helpers

  # Public chapter listing always hides unreadable chapters; the gate is
  # forced server-side so client params can never opt back into them.
  defp list_public_chapters(series_id, params) do
    Catalog.list_chapters(series_id, Map.put(params, "status", "available"))
  end

  defp parse_thread_id(nil), do: nil
  defp parse_thread_id(id) when is_integer(id) and id > 0, do: id

  defp parse_thread_id(id) when is_binary(id) do
    case Integer.parse(String.trim(id)) do
      {int, ""} when int > 0 -> int
      _ -> nil
    end
  end

  defp parse_thread_id(_), do: nil

  defp load_comment_tree(series, thread_id, params) do
    if is_integer(thread_id) do
      case Crysa.Comments.get_comment(thread_id) do
        %Crysa.Comments.Comment{series_id: sid} = _c when sid == series.id ->
          {tree, pagination} = Crysa.Comments.list_thread_tree(thread_id)
          # Thread tree is single root; pagination is for that thread
          {tree, pagination, true}

        _ ->
          {tree, pagination} = Crysa.Comments.list_comment_tree_for_series(series.id, params)
          {tree, pagination, false}
      end
    else
      {tree, pagination} = Crysa.Comments.list_comment_tree_for_series(series.id, params)
      {tree, pagination, false}
    end
  end

  # Helpers

  defp reload_series(series_id) do
    # Use admin variant to ensure we get fresh counters even if archived? Public should not be archived here.
    # Fallback to get_series.
    Crysa.Repo.get!(Crysa.Catalog.Series, series_id)
    |> Crysa.Repo.preload([:authors, :categories])
  end

  defp user_library_state(nil, _series), do: {false, nil}

  defp user_library_state(%{} = user, series) do
    bookmarked = Library.bookmarked?(user, series)
    rating = Library.get_rating(user, series)
    user_rating = if rating, do: rating.rating, else: nil
    {bookmarked, user_rating}
  end

  defp to_series_json(nil), do: nil

  defp to_series_json(series) do
    %{
      id: series.id,
      title: series.title,
      slug: series.slug,
      description: series.description,
      coverUrl: series.cover_url,
      sourceUrl: series.source_url,
      publicationStatus: series.publication_status,
      processingStatus: series.processing_status,
      chapterCount: series.chapter_count || 0,
      viewCount: series.view_count || 0,
      bookmarkCount: series.bookmark_count || 0,
      ratingCount: series.rating_count || 0,
      ratingSum: series.rating_sum || 0,
      lastChapterAt: series.last_chapter_at && DateTime.to_iso8601(series.last_chapter_at),
      updatedAt: series.updated_at && DateTime.to_iso8601(series.updated_at),
      insertedAt: series.inserted_at && DateTime.to_iso8601(series.inserted_at)
    }
  end

  defp to_author_json(author), do: %{id: author.id, name: author.name}
  defp to_category_json(cat), do: %{id: cat.id, name: cat.name}

  defp to_stats_json(series) do
    %{
      chapters: series.chapter_count || 0,
      views: series.view_count || 0,
      bookmarked: series.bookmark_count || 0,
      status: series.publication_status || "ongoing"
    }
  end

  defp rating_summary_to_json(%{count: count, sum: sum, average: avg}) do
    %{
      count: count,
      sum: sum,
      average: avg && Float.round(avg, 1)
    }
  end

  defp to_chapter_json(nil), do: nil

  defp to_chapter_json(ch) do
    %{
      id: ch.id,
      chapterKey: ch.chapter_key,
      displayNumber: ch.display_number,
      title: ch.title,
      sortKey: ch.sort_key,
      publishedAt: ch.published_at && DateTime.to_iso8601(ch.published_at),
      insertedAt: ch.inserted_at && DateTime.to_iso8601(ch.inserted_at)
    }
  end

  defp to_comment_json(c, counts) do
    {up, down} =
      case counts do
        %{up: u, down: d} -> {u, d}
        _ -> {0, 0}
      end

    %{
      id: c.id,
      bodyMarkdown: c.body_markdown,
      bodyHtml: c.body_html,
      voteScore: c.vote_score || 0,
      upCount: up,
      downCount: down,
      insertedAt: c.inserted_at && DateTime.to_iso8601(c.inserted_at),
      user: c.user && %{id: c.user.id, username: c.user.username},
      parentId: c.parent_id
    }
  end

  # Tree JSON for Recursive CommentThread (Reddit-style)
  defp to_comment_node_json(%{
         comment: c,
         depth: depth,
         deleted: deleted,
         has_more: has_more,
         reply_count: reply_count,
         vote_counts: counts,
         children: children
       }) do
    {up, down} =
      case counts do
        %{up: u, down: d} -> {u, d}
        _ -> {0, 0}
      end

    %{
      id: c.id,
      bodyMarkdown: if(deleted, do: nil, else: c.body_markdown),
      bodyHtml:
        if(deleted,
          do: "<p class=\"italic text-muted-foreground text-xs\">[deleted]</p>",
          else: c.body_html
        ),
      voteScore: c.vote_score || 0,
      upCount: up,
      downCount: down,
      insertedAt: c.inserted_at && DateTime.to_iso8601(c.inserted_at),
      user: if(deleted, do: nil, else: c.user && %{id: c.user.id, username: c.user.username}),
      parentId: c.parent_id,
      depth: depth,
      deleted: deleted,
      hasMore: has_more,
      replyCount: reply_count,
      children: Enum.map(children, &to_comment_node_json/1)
    }
  end

  # Flattens tree nodes to a list of Comment structs (for flat `comments` compat and vote_counts batching)
  defp flatten_comment_tree(nodes) when is_list(nodes) do
    Enum.flat_map(nodes, fn %{comment: c, children: children} ->
      [c | flatten_comment_tree(children)]
    end)
  end

  defp to_user_json(nil), do: nil
  defp to_user_json(user), do: %{id: user.id, username: user.username, email: user.email}

  defp to_pagination_json(p) do
    %{
      page: p.page,
      pageSize: p.page_size,
      totalEntries: p.total_entries,
      totalPages: p.total_pages,
      hasPrevious: p.page > 1,
      hasNext: p.page < p.total_pages
    }
  end

  defp parse_q(params, key) do
    case Map.get(params, key) do
      v when is_binary(v) ->
        trimmed = String.trim(v)
        if trimmed == "", do: nil, else: String.slice(trimmed, 0, 100)

      _ ->
        nil
    end
  end

  defp parse_page(params, key) do
    case Map.get(params, key) do
      v when is_integer(v) and v > 0 ->
        v

      v when is_binary(v) ->
        case Integer.parse(v) do
          {int, ""} when int > 0 -> int
          _ -> 1
        end

      _ ->
        1
    end
  end

  defp parse_int(v, default) do
    case Integer.parse(to_string(v)) do
      {int, ""} -> int
      _ -> default
    end
  end

  defp parse_chapter_sort(%{"sort" => sort}) when sort in ["newest", "oldest"], do: sort
  defp parse_chapter_sort(%{"chapter_sort" => sort}) when sort in ["newest", "oldest"], do: sort
  defp parse_chapter_sort(_), do: "newest"

  defp parse_comment_sort(%{"sort" => sort}) when sort in ["newest", "oldest", "most_voted"],
    do: sort

  defp parse_comment_sort(%{"comment_sort" => sort})
       when sort in ["newest", "oldest", "most_voted"], do: sort

  defp parse_comment_sort(_), do: "newest"

  # Helpers for handle_params that need to distinguish missing vs present key
  defp parse_chapter_sort_opt(params, key) do
    case Map.get(params, key) do
      sort when sort in ["newest", "oldest"] -> sort
      _ -> nil
    end
  end

  defp parse_comment_sort_opt(params, key) do
    case Map.get(params, key) do
      sort when sort in ["newest", "oldest", "most_voted"] -> sort
      _ -> nil
    end
  end

  defp extract_changeset_error(%Ecto.Changeset{errors: errors}) do
    case errors do
      [] -> "Invalid input."
      [{_field, {msg, _opts}} | _] -> msg
      _ -> "Invalid input."
    end
  end

  defp humanize_comment_error(:parent_not_found), do: "Parent comment not found."
  defp humanize_comment_error(:parent_deleted), do: "Parent comment was deleted."
  defp humanize_comment_error(:parent_target_mismatch), do: "Reply target mismatch."
  defp humanize_comment_error(other), do: to_string(other)
end
