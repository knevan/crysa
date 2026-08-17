defmodule Crysa.Catalog do
  @moduledoc """
  Catalog context for series, chapters, images, authors, and categories.
  """

  alias Crysa.Catalog.{Author, Category, Chapter, ChapterImage, Series}
  alias Crysa.Repo

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

  @spec create_chapter(map()) :: {:ok, Chapter.t()} | {:error, Ecto.Changeset.t()}
  def create_chapter(attrs), do: %Chapter{} |> Chapter.changeset(attrs) |> Repo.insert()

  @spec create_chapter_image(map()) :: {:ok, ChapterImage.t()} | {:error, Ecto.Changeset.t()}
  def create_chapter_image(attrs),
    do: %ChapterImage{} |> ChapterImage.changeset(attrs) |> Repo.insert()

  @spec create_category(map()) :: {:ok, Category.t()} | {:error, Ecto.Changeset.t()}
  def create_category(attrs), do: %Category{} |> Category.changeset(attrs) |> Repo.insert()

  @spec create_author(map()) :: {:ok, Author.t()} | {:error, Ecto.Changeset.t()}
  def create_author(attrs), do: %Author{} |> Author.changeset(attrs) |> Repo.insert()
end
