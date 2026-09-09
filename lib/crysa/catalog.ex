defmodule Crysa.Catalog do
  @moduledoc """
  Catalog context for series, chapters, chapter images, authors, and categories.

  Provides the write API (CRUD and association management) and the public
  read model (browse, search, detail, reader). All user input enters through
  changesets or through the validated parsers in `Crysa.Catalog.Query`.
  """

  alias Crysa.Catalog.{Author, Category, Chapter, ChapterImage, Normalization, Query, Series}
  alias Crysa.Pagination
  alias Crysa.Processing.CheckSchedule
  alias Crysa.Repo
  alias Crysa.Storage

  import Ecto.Query

  require Logger

  @publication_statuses ~w(ongoing completed hiatus discontinued)
  @series_processing_statuses ~w(pending processing available error pending_deletion deleting deletion_failed)
  @chapter_statuses ~w(pending processing available no_images_found error)

  @spec publication_statuses() :: [String.t()]
  def publication_statuses, do: @publication_statuses

  @spec series_processing_statuses() :: [String.t()]
  def series_processing_statuses, do: @series_processing_statuses

  @spec chapter_statuses() :: [String.t()]
  def chapter_statuses, do: @chapter_statuses

  @spec create_series(map()) :: {:ok, Series.t()} | {:error, Ecto.Changeset.t()}
  def create_series(attrs) when is_map(attrs) do
    # Inject check scheduling (`next_check_at`) when the caller does not
    # provide one explicitly. The effective interval is derived from
    # `publication_status` / `manual_check_interval_minutes` with the same
    # policy the workers use, plus proportional jitter. Discontinued series
    # remain unscheduled (`nil`).
    attrs = maybe_inject_next_check(attrs)
    %Series{} |> Series.create_changeset(attrs) |> Repo.insert()
  end

  @spec update_series(Series.t(), map()) :: {:ok, Series.t()} | {:error, Ecto.Changeset.t()}
  def update_series(%Series{} = series, attrs) when is_map(attrs) do
    changeset = Series.update_changeset(series, attrs)
    changeset = maybe_reschedule(changeset, series)
    Repo.update(changeset)
  end

  @doc """
  Resolves the public cover URL for a series from its stored storage key.

  The database holds the opaque storage key; URL construction (adapter
  prefix or CDN base) happens here at the presentation boundary so stored
  data stays identical across environments.
  """
  @spec cover_url(Series.t() | nil) :: String.t() | nil
  def cover_url(%Series{cover_key: key}) when is_binary(key) and key != "",
    do: Storage.url_for(key)

  def cover_url(_), do: nil

  defp maybe_inject_next_check(attrs) do
    # Normalize once to avoid dual atom/string access (Credo warning)
    normalized = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

    if Map.has_key?(normalized, "next_check_at") do
      attrs
    else
      manual = Map.get(normalized, "manual_check_interval_minutes")
      status = Map.get(normalized, "publication_status") || "ongoing"

      schedule_input = %{
        manual_check_interval_minutes: manual,
        publication_status: to_string(status),
        check_retry_count: 0
      }

      case CheckSchedule.next_check_at(DateTime.utc_now(), schedule_input) do
        nil -> attrs
        next -> Map.put(attrs, :next_check_at, next)
      end
    end
  end

  defp maybe_reschedule(changeset, %Series{} = series) do
    has_pub = Map.has_key?(changeset.changes, :publication_status)
    has_manual = Map.has_key?(changeset.changes, :manual_check_interval_minutes)
    has_archived = Map.has_key?(changeset.changes, :archived_at)

    if has_pub or has_manual or has_archived do
      effective_manual =
        case Ecto.Changeset.fetch_change(changeset, :manual_check_interval_minutes) do
          {:ok, v} -> v
          :error -> series.manual_check_interval_minutes
        end

      effective_status =
        case Ecto.Changeset.fetch_change(changeset, :publication_status) do
          {:ok, v} -> v
          :error -> series.publication_status
        end

      effective_archived =
        case Ecto.Changeset.fetch_change(changeset, :archived_at) do
          {:ok, v} -> v
          :error -> series.archived_at
        end

      schedule_input = %{
        archived_at: effective_archived,
        manual_check_interval_minutes: effective_manual,
        publication_status: to_string(effective_status),
        check_retry_count: series.check_retry_count || 0
      }

      next = CheckSchedule.next_check_at(DateTime.utc_now(), schedule_input)
      Ecto.Changeset.put_change(changeset, :next_check_at, next)
    else
      changeset
    end
  end

  @doc """
  Admin helper to update scheduling fields for a series.

  Accepts `%{publication_status: ..., manual_check_interval_minutes: ...}`
  (either atom or string keys). `manual_check_interval_minutes` may be
  `nil` to reset to auto (status-derived). Returns the updated series or
  a changeset error. The write recomputes `next_check_at` atomically via
  `maybe_reschedule/2`.
  """
  @spec update_series_schedule(Series.t(), map()) ::
          {:ok, Series.t()} | {:error, Ecto.Changeset.t()}
  def update_series_schedule(%Series{} = series, attrs) when is_map(attrs) do
    normalized = normalize_schedule_attrs(attrs)
    update_series(series, normalized)
  end

  defp normalize_schedule_attrs(attrs) when is_map(attrs) do
    # Accept both string and atom keys; normalize manual interval to
    # integer | nil so the changeset validation (15..10080) applies
    # uniformly. Empty string / "auto" means reset to status-derived.
    Enum.reduce(attrs, %{}, fn {k, v}, acc ->
      key =
        if is_atom(k), do: Atom.to_string(k), else: to_string(k)

      case key do
        "publication_status" ->
          Map.put(acc, :publication_status, v)

        "manual_check_interval_minutes" ->
          Map.put(acc, :manual_check_interval_minutes, normalize_manual_interval(v))

        "manual_interval" ->
          Map.put(acc, :manual_check_interval_minutes, normalize_manual_interval(v))

        "next_check_at" ->
          Map.put(acc, :next_check_at, v)

        _ ->
          acc
      end
    end)
    |> then(fn map ->
      # Also keep string-key version for cast compatibility, but Ecto cast
      # handles atom keys already; we just ensure the key exists. If the
      # caller sent no scheduling keys, return empty map so update_series
      # becomes a no-op (handled upstream).
      map
    end)
  end

  defp normalize_manual_interval(nil), do: nil
  defp normalize_manual_interval(""), do: nil
  defp normalize_manual_interval("auto"), do: nil
  defp normalize_manual_interval(v) when is_integer(v), do: v

  defp normalize_manual_interval(v) when is_binary(v) do
    trimmed = String.trim(v)

    cond do
      trimmed == "" ->
        nil

      trimmed == "auto" ->
        nil

      true ->
        case Integer.parse(trimmed) do
          {int, ""} -> int
          _ -> v
        end
    end
  end

  defp normalize_manual_interval(v), do: v

  @spec effective_interval_minutes(Series.t() | map()) :: pos_integer() | nil
  def effective_interval_minutes(series), do: CheckSchedule.effective_interval_minutes(series)

  @doc """
  Archives a series — delists it from all public user queries.

  Sets `archived_at` to now and clears `next_check_at` so the scheduler
  never picks it (`CheckSchedule` returns `nil` for archived). The row stays
  in DB + storage until a later `admin_delete_series/1` hard-deletes it.
  Reversible via `unarchive_series/1`.
  """
  @spec archive_series(Series.t()) :: {:ok, Series.t()} | {:error, Ecto.Changeset.t()}
  def archive_series(%Series{} = series) do
    if series.archived_at do
      {:ok, series}
    else
      series
      |> Series.update_changeset(%{archived_at: DateTime.utc_now(), next_check_at: nil})
      |> Repo.update()
    end
  end

  @doc """
  Unarchives a series — makes it visible again and recomputes `next_check_at`.
  """
  @spec unarchive_series(Series.t()) :: {:ok, Series.t()} | {:error, Ecto.Changeset.t()}
  def unarchive_series(%Series{} = series) do
    if is_nil(series.archived_at) do
      {:ok, series}
    else
      changeset = Series.update_changeset(series, %{archived_at: nil})
      # Recompute next_check_at from current publication_status/manual (archived cleared)
      changeset = maybe_reschedule(changeset, %{series | archived_at: nil})
      Repo.update(changeset)
    end
  end

  @spec delete_series(Series.t()) :: {:ok, Series.t()} | {:error, Ecto.Changeset.t()}
  def delete_series(%Series{} = series), do: Repo.delete(series)

  @doc """
  Admin hard-delete for a series — removes DB rows **and** object storage.

  Unlike `delete_series/1` (immediate `Repo.delete` without storage), this
  follows the durable state machine `pending_deletion → deleting → deleted`
  via `Crysa.Processing.Jobs.SeriesDeletionWorker`:

    * Marks the series `pending_deletion` (fails if already pending/deleting).
    * Enqueues a unique `SeriesDeletionWorker` job (`series_id`).
    * The worker deletes `cover` + all `chapter_images` storage keys
      (`Storage.delete_many/1`, chunked, idempotent, outside any DB tx)
      then cascades `Repo.delete` to chapters/images/comments.

  This prevents DB + storage bloat that an archive-only flow would leave.
  Returns `{:ok, series_in_pending_deletion}` or `{:error, reason}`.
  """
  @spec admin_delete_series(integer() | Series.t()) ::
          {:ok, Series.t()}
          | {:error, :not_found | :already_pending_deletion | Ecto.Changeset.t() | term()}
  def admin_delete_series(series_id) when is_integer(series_id) do
    case Repo.get(Series, series_id) do
      nil -> {:error, :not_found}
      %Series{} = series -> admin_delete_series(series)
    end
  end

  def admin_delete_series(%Series{} = series) do
    if series.processing_status in ["pending_deletion", "deleting"] do
      {:error, :already_pending_deletion}
    else
      changeset = Series.update_changeset(series, %{processing_status: "pending_deletion"})

      case Repo.update(changeset) do
        {:ok, pending} ->
          # Enqueue durable deletion; uniqueness prevents duplicate jobs.
          job = Crysa.Processing.Jobs.SeriesDeletionWorker.new(%{series_id: pending.id})

          case Oban.insert(job) do
            {:ok, _job} -> {:ok, pending}
            {:error, reason} -> {:error, reason}
          end

        {:error, cs} ->
          {:error, cs}
      end
    end
  end

  @spec get_series(integer()) :: Series.t() | nil
  def get_series(id) when is_integer(id), do: Repo.get(Series, id)

  @spec get_series_by_slug(String.t()) :: Series.t() | nil
  def get_series_by_slug(slug) when is_binary(slug), do: Query.get_series_by_slug(slug)

  @spec get_series_by_slug_admin(String.t()) :: Series.t() | nil
  def get_series_by_slug_admin(slug) when is_binary(slug),
    do: Query.get_series_by_slug_admin(slug)

  @spec create_chapter(map()) :: {:ok, Chapter.t()} | {:error, Ecto.Changeset.t()}
  def create_chapter(attrs), do: %Chapter{} |> Chapter.create_changeset(attrs) |> Repo.insert()

  @spec update_chapter(Chapter.t(), map()) :: {:ok, Chapter.t()} | {:error, Ecto.Changeset.t()}
  def update_chapter(%Chapter{} = chapter, attrs),
    do: chapter |> Chapter.update_changeset(attrs) |> Repo.update()

  @spec delete_chapter(Chapter.t()) :: {:ok, Chapter.t()} | {:error, Ecto.Changeset.t()}
  def delete_chapter(%Chapter{} = chapter), do: Repo.delete(chapter)

  @spec get_chapter(integer()) :: Chapter.t() | nil
  def get_chapter(id) when is_integer(id), do: Repo.get(Chapter, id)

  @doc """
  Admin chapter listing with bounded pagination.

  Thin wrapper over `Query.list_chapters/2` so the LiveView depends only on
  the context boundary.
  """
  @spec admin_list_chapters(integer(), map()) :: {[Chapter.t()], Pagination.t()}
  def admin_list_chapters(series_id, params \\ %{}) when is_integer(series_id),
    do: Query.list_chapters(series_id, params)

  @doc """
  Admin deletion of a single chapter.

  Improved over Castra's `delete_chapter_and_images_for_chapter` which left
  orphaned storage objects and used a float `chapter_number` key:

    * Identity is stable `chapter_id` (integer), not `f32` chapter_number.
    * Storage objects are deleted *before* the DB row, outside any
      transaction (plan: never hold a DB transaction across network I/O).
    * If storage deletion fails the DB row is left intact so the operation
      can be retried without leaking orphaned rows.
    * Series derived counters (`chapter_count`, `last_chapter_at`) are
      recomputed transactionally after the delete.
  """
  @spec admin_delete_chapter(integer() | Chapter.t()) ::
          {:ok, Chapter.t()}
          | {:error, :not_found | {:storage_delete_failed, term()} | Ecto.Changeset.t()}
  def admin_delete_chapter(chapter_id) when is_integer(chapter_id) do
    case Repo.get(Chapter, chapter_id) do
      nil -> {:error, :not_found}
      %Chapter{} = ch -> admin_delete_chapter(ch)
    end
  end

  def admin_delete_chapter(%Chapter{id: chapter_id, series_id: series_id} = chapter) do
    keys =
      Repo.all(
        from(i in ChapterImage,
          where: i.chapter_id == ^chapter_id and not is_nil(i.storage_key),
          select: i.storage_key
        )
      )

    case Crysa.Storage.delete_many(keys) do
      :ok ->
        Repo.transaction(fn ->
          # Images are cascade-deleted but we delete explicitly for clarity.
          Repo.delete_all(from(i in ChapterImage, where: i.chapter_id == ^chapter_id))

          case Repo.delete(chapter) do
            {:ok, deleted} ->
              refresh_series_counters(series_id)
              deleted

            {:error, cs} ->
              Repo.rollback(cs)
          end
        end)
        |> case do
          {:ok, deleted} -> {:ok, deleted}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} = err ->
        Logger.warning("chapter delete storage cleanup failed",
          chapter_id: chapter_id,
          series_id: series_id,
          reason: inspect(reason)
        )

        err
    end
  end

  @doc """
  Enqueues a repair job for a chapter, optionally with a replacement URL.

  Mirrors Castra's `repair_chapter` flow but with durable Oban jobs
  instead of an in-memory channel and with URL host validation against the
  published scraping config. When `new_source_url` is `nil` the chapter's
  existing URL is reused.
  """
  @spec admin_repair_chapter(integer(), String.t() | nil) ::
          {:ok, Oban.Job.t()} | {:error, :not_found | :invalid_url | :no_site_config | term()}
  def admin_repair_chapter(chapter_id, new_source_url \\ nil) when is_integer(chapter_id) do
    case Repo.get(Chapter, chapter_id) do
      nil ->
        {:error, :not_found}

      %Chapter{} = chapter ->
        with {:ok, url} <- resolve_repair_url(chapter, new_source_url),
             {:ok, _snapshot} <- validate_repair_host(url) do
          args =
            if is_binary(new_source_url) and String.trim(new_source_url) != "" do
              %{"chapter_id" => chapter_id, "new_source_url" => String.trim(new_source_url)}
            else
              %{"chapter_id" => chapter_id}
            end

          args
          |> Crysa.Processing.Jobs.ChapterRepairWorker.new()
          |> Oban.insert()
          |> case do
            {:ok, job} -> {:ok, job}
            {:error, reason} -> {:error, reason}
          end
        else
          {:error, _} = err -> err
        end
    end
  end

  defp resolve_repair_url(%Chapter{source_url: existing}, nil), do: {:ok, existing}
  defp resolve_repair_url(%Chapter{source_url: existing}, ""), do: {:ok, existing}

  defp resolve_repair_url(_chapter, new_url) when is_binary(new_url) do
    trimmed = String.trim(new_url)

    if trimmed == "" do
      {:error, :invalid_url}
    else
      case URI.parse(trimmed) do
        %URI{scheme: scheme, host: host}
        when scheme in ["http", "https"] and is_binary(host) and host != "" ->
          {:ok, trimmed}

        _ ->
          {:error, :invalid_url}
      end
    end
  end

  defp resolve_repair_url(_, _), do: {:error, :invalid_url}

  defp validate_repair_host(url) do
    host = URI.parse(url) |> Map.get(:host) || "unknown"
    Crysa.Scraping.published_config_for_host(host)
  end

  defp refresh_series_counters(series_id) do
    {count, latest} =
      Repo.one(
        from(c in Chapter,
          where: c.series_id == ^series_id and c.status == "available",
          select: {count(), max(c.published_at)}
        )
      ) || {0, nil}

    Repo.update_all(
      from(s in Series, where: s.id == ^series_id),
      set: [chapter_count: count, last_chapter_at: latest]
    )
  end

  @spec get_chapter_by_key(integer(), String.t()) :: Chapter.t() | nil
  def get_chapter_by_key(series_id, chapter_key) when is_integer(series_id),
    do: Query.get_reader_chapter(series_id, chapter_key)

  @spec create_chapter_image(map()) :: {:ok, ChapterImage.t()} | {:error, Ecto.Changeset.t()}
  def create_chapter_image(attrs),
    do: %ChapterImage{} |> ChapterImage.changeset(attrs) |> Repo.insert()

  @spec update_chapter_image(ChapterImage.t(), map()) ::
          {:ok, ChapterImage.t()} | {:error, Ecto.Changeset.t()}
  def update_chapter_image(%ChapterImage{} = image, attrs),
    do: image |> ChapterImage.changeset(attrs) |> Repo.update()

  @spec delete_chapter_image(ChapterImage.t()) ::
          {:ok, ChapterImage.t()} | {:error, Ecto.Changeset.t()}
  def delete_chapter_image(%ChapterImage{} = image), do: Repo.delete(image)

  @spec create_category(map()) :: {:ok, Category.t()} | {:error, Ecto.Changeset.t()}
  def create_category(attrs), do: %Category{} |> Category.changeset(attrs) |> Repo.insert()

  @spec update_category(Category.t(), map()) :: {:ok, Category.t()} | {:error, Ecto.Changeset.t()}
  def update_category(%Category{} = category, attrs),
    do: category |> Category.changeset(attrs) |> Repo.update()

  @spec delete_category(Category.t()) :: {:ok, Category.t()} | {:error, Ecto.Changeset.t()}
  def delete_category(%Category{} = category), do: Repo.delete(category)

  @spec get_category(integer()) :: Category.t() | nil
  def get_category(id) when is_integer(id), do: Repo.get(Category, id)

  @spec get_category_by_name(String.t()) :: Category.t() | nil
  def get_category_by_name(name) when is_binary(name),
    do: Repo.get_by(Category, normalized_name: Normalization.normalized_name(name))

  @spec get_or_create_category(String.t()) :: {:ok, Category.t()}
  def get_or_create_category(name) when is_binary(name) do
    normalized = Normalization.normalized_name(name)

    Repo.insert(Category.changeset(%Category{}, %{name: name}),
      on_conflict: :nothing,
      conflict_target: [:normalized_name]
    )

    {:ok, Repo.get_by!(Category, normalized_name: normalized)}
  end

  @spec create_author(map()) :: {:ok, Author.t()} | {:error, Ecto.Changeset.t()}
  def create_author(attrs), do: %Author{} |> Author.changeset(attrs) |> Repo.insert()

  @spec update_author(Author.t(), map()) :: {:ok, Author.t()} | {:error, Ecto.Changeset.t()}
  def update_author(%Author{} = author, attrs),
    do: author |> Author.changeset(attrs) |> Repo.update()

  @spec delete_author(Author.t()) :: {:ok, Author.t()} | {:error, Ecto.Changeset.t()}
  def delete_author(%Author{} = author), do: Repo.delete(author)

  @spec get_author(integer()) :: Author.t() | nil
  def get_author(id) when is_integer(id), do: Repo.get(Author, id)

  @spec get_author_by_name(String.t()) :: Author.t() | nil
  def get_author_by_name(name) when is_binary(name),
    do: Repo.get_by(Author, normalized_name: Normalization.normalized_name(name))

  @spec get_or_create_author(String.t()) :: {:ok, Author.t()}
  def get_or_create_author(name) when is_binary(name) do
    normalized = Normalization.normalized_name(name)

    Repo.insert(Author.changeset(%Author{}, %{name: name}),
      on_conflict: :nothing,
      conflict_target: [:normalized_name]
    )

    {:ok, Repo.get_by!(Author, normalized_name: normalized)}
  end

  @spec set_series_categories(Series.t(), [Category.t()]) ::
          {:ok, Series.t()} | {:error, Ecto.Changeset.t()}
  def set_series_categories(%Series{} = series, categories) when is_list(categories) do
    series
    |> Repo.preload(:categories)
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.put_assoc(:categories, categories)
    |> Repo.update()
  end

  @spec add_series_category(Series.t(), Category.t()) :: :ok
  def add_series_category(%Series{id: series_id}, %Category{id: category_id}) do
    Repo.insert_all(
      "series_categories",
      [%{series_id: series_id, category_id: category_id}],
      on_conflict: :nothing,
      conflict_target: [:series_id, :category_id]
    )

    :ok
  end

  @spec remove_series_category(Series.t(), Category.t()) :: :ok
  def remove_series_category(%Series{id: series_id}, %Category{id: category_id}) do
    Repo.delete_all(
      from(sc in "series_categories",
        where: sc.series_id == ^series_id and sc.category_id == ^category_id
      )
    )

    :ok
  end

  @spec set_series_authors(Series.t(), [Author.t()]) ::
          {:ok, Series.t()} | {:error, Ecto.Changeset.t()}
  def set_series_authors(%Series{} = series, authors) when is_list(authors) do
    series
    |> Repo.preload(:authors)
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.put_assoc(:authors, authors)
    |> Repo.update()
  end

  @spec add_series_author(Series.t(), Author.t()) :: :ok
  def add_series_author(%Series{id: series_id}, %Author{id: author_id}) do
    Repo.insert_all(
      "series_authors",
      [%{series_id: series_id, author_id: author_id}],
      on_conflict: :nothing,
      conflict_target: [:series_id, :author_id]
    )

    :ok
  end

  @spec remove_series_author(Series.t(), Author.t()) :: :ok
  def remove_series_author(%Series{id: series_id}, %Author{id: author_id}) do
    Repo.delete_all(
      from(sa in "series_authors",
        where: sa.series_id == ^series_id and sa.author_id == ^author_id
      )
    )

    :ok
  end

  @doc """
  Admin series listing for the dashboard TanStack table.

  Thin wrapper over `Crysa.Catalog.Query.admin_list_series/1` so the LiveView
  depends only on the context boundary. Returns preloaded `:authors` for each
  series row.
  """
  @spec admin_list_series(map()) :: {[Series.t()], Pagination.t()}
  def admin_list_series(params \\ %{}) when is_map(params),
    do: Query.admin_list_series(params)

  @spec browse_series(map()) :: {[Series.t()], Pagination.t()}
  def browse_series(params \\ %{}) when is_map(params), do: Query.browse_series(params)

  @spec list_new_series(map()) :: {[Series.t()], Pagination.t()}
  def list_new_series(params \\ %{}) when is_map(params), do: Query.list_new_series(params)

  @spec list_most_viewed(map()) :: {[Series.t()], Pagination.t()}
  def list_most_viewed(params \\ %{}) when is_map(params), do: Query.list_most_viewed(params)

  @spec list_latest_updates(map()) :: {[Series.t()], Pagination.t()}
  def list_latest_updates(params \\ %{}) when is_map(params),
    do: Query.list_latest_updates(params)

  @spec list_chapters(integer(), map()) :: {[Chapter.t()], Pagination.t()}
  def list_chapters(series_id, params \\ %{}) when is_integer(series_id),
    do: Query.list_chapters(series_id, params)

  @spec list_categories() :: [Category.t()]
  def list_categories do
    import Ecto.Query
    Crysa.Repo.all(from c in Category, order_by: [asc: c.name])
  end

  @spec list_categories_with_counts() :: [{Category.t(), non_neg_integer()}]
  def list_categories_with_counts, do: Query.list_categories_with_counts()

  @spec get_latest_chapter(integer()) :: Chapter.t() | nil
  def get_latest_chapter(series_id) when is_integer(series_id),
    do: Query.get_latest_chapter(series_id)

  @spec get_reader_chapter(integer(), String.t()) :: Chapter.t() | nil
  def get_reader_chapter(series_id, chapter_key) when is_integer(series_id),
    do: Query.get_reader_chapter(series_id, chapter_key)

  @spec chapter_navigation(integer(), String.t()) :: {map() | nil, map() | nil}
  def chapter_navigation(series_id, chapter_key) when is_integer(series_id),
    do: Query.chapter_navigation(series_id, chapter_key)
end
