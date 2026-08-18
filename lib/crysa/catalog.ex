defmodule Crysa.Catalog do
  @moduledoc """
  Catalog context for series, chapters, chapter images, authors, and categories.

  Provides the write API (CRUD and association management) and the public
  read model (browse, search, detail, reader). All user input enters through
  changesets or through the validated parsers in `Crysa.Catalog.Query`.
  """

  alias Crysa.Catalog.{Author, Category, Chapter, ChapterImage, Normalization, Query, Series}
  alias Crysa.Pagination
  alias Crysa.Repo

  import Ecto.Query

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
  def create_series(attrs), do: %Series{} |> Series.create_changeset(attrs) |> Repo.insert()

  @spec update_series(Series.t(), map()) :: {:ok, Series.t()} | {:error, Ecto.Changeset.t()}
  def update_series(%Series{} = series, attrs),
    do: series |> Series.update_changeset(attrs) |> Repo.update()

  @spec delete_series(Series.t()) :: {:ok, Series.t()} | {:error, Ecto.Changeset.t()}
  def delete_series(%Series{} = series), do: Repo.delete(series)

  @spec get_series(integer()) :: Series.t() | nil
  def get_series(id) when is_integer(id), do: Repo.get(Series, id)

  @spec get_series_by_slug(String.t()) :: Series.t() | nil
  def get_series_by_slug(slug) when is_binary(slug), do: Query.get_series_by_slug(slug)

  @spec create_chapter(map()) :: {:ok, Chapter.t()} | {:error, Ecto.Changeset.t()}
  def create_chapter(attrs), do: %Chapter{} |> Chapter.create_changeset(attrs) |> Repo.insert()

  @spec update_chapter(Chapter.t(), map()) :: {:ok, Chapter.t()} | {:error, Ecto.Changeset.t()}
  def update_chapter(%Chapter{} = chapter, attrs),
    do: chapter |> Chapter.update_changeset(attrs) |> Repo.update()

  @spec delete_chapter(Chapter.t()) :: {:ok, Chapter.t()} | {:error, Ecto.Changeset.t()}
  def delete_chapter(%Chapter{} = chapter), do: Repo.delete(chapter)

  @spec get_chapter(integer()) :: Chapter.t() | nil
  def get_chapter(id) when is_integer(id), do: Repo.get(Chapter, id)

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
