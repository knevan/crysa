defmodule Crysa.Catalog.Series do
  @moduledoc """
  Manga/manhwa series metadata and aggregate counters.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Crysa.Catalog
  alias Crysa.Catalog.{Author, Category, Chapter}

  @type t :: %__MODULE__{}

  schema "series" do
    field :title, :string
    field :slug, :string
    field :description, :string
    field :cover_url, :string
    field :source_url, :string
    field :publication_status, :string, default: "ongoing"
    field :processing_status, :string, default: "pending"
    field :chapter_count, :integer, default: 0
    field :bookmark_count, :integer, default: 0
    field :view_count, :integer, default: 0
    field :rating_count, :integer, default: 0
    field :rating_sum, :integer, default: 0
    field :next_check_at, :utc_datetime
    field :last_checked_at, :utc_datetime
    field :check_interval_minutes, :integer, default: 60
    field :last_chapter_at, :utc_datetime
    field :last_error, :string

    has_many :chapters, Chapter
    many_to_many :categories, Category, join_through: "series_categories"
    many_to_many :authors, Author, join_through: "series_authors"

    timestamps(type: :utc_datetime)
  end

  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(series, attrs) do
    series
    |> cast(attrs, [
      :title,
      :slug,
      :description,
      :cover_url,
      :source_url,
      :publication_status,
      :processing_status,
      :chapter_count,
      :bookmark_count,
      :view_count,
      :rating_count,
      :rating_sum,
      :next_check_at,
      :last_checked_at,
      :check_interval_minutes,
      :last_chapter_at,
      :last_error
    ])
    |> normalize_text_fields()
    |> validate_required([:title, :slug, :source_url, :publication_status, :processing_status])
    |> validate_inclusion(:publication_status, Catalog.publication_statuses())
    |> validate_inclusion(:processing_status, Catalog.series_processing_statuses())
    |> validate_number(:chapter_count, greater_than_or_equal_to: 0)
    |> validate_number(:bookmark_count, greater_than_or_equal_to: 0)
    |> validate_number(:view_count, greater_than_or_equal_to: 0)
    |> validate_number(:rating_count, greater_than_or_equal_to: 0)
    |> validate_number(:rating_sum, greater_than_or_equal_to: 0)
    |> validate_number(:check_interval_minutes,
      greater_than_or_equal_to: 15,
      less_than_or_equal_to: 10_080
    )
    |> validate_length(:last_error, max: 2_000)
    |> check_constraint(:publication_status, name: :series_publication_status_check)
    |> check_constraint(:processing_status, name: :series_processing_status_check)
    |> unique_constraint(:slug)
    |> unique_constraint(:source_url)
  end

  defp normalize_text_fields(changeset) do
    changeset
    |> update_change(:title, &trim/1)
    |> update_change(:slug, &slugify/1)
    |> update_change(:source_url, &trim/1)
  end

  defp slugify(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp slugify(value), do: value
  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value
end
