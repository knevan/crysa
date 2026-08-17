defmodule Crysa.Catalog.Chapter do
  @moduledoc """
  Chapter metadata with canonical text identity and sortable metadata.
  """

  use Ecto.Schema

  import Ecto.Changeset
  alias Crysa.Catalog
  alias Crysa.Catalog.{ChapterImage, Series}

  @type t :: %__MODULE__{}

  schema "series_chapters" do
    field :chapter_key, :string
    field :display_number, :string
    field :title, :string
    field :chapter_number, :decimal
    field :sort_key, :string
    field :source_url, :string
    field :status, :string, default: "pending"
    field :retry_count, :integer, default: 0
    field :last_error, :string
    field :last_attempted_at, :utc_datetime
    field :locked_at, :utc_datetime
    field :published_at, :utc_datetime

    belongs_to :series, Series
    has_many :images, ChapterImage

    timestamps(type: :utc_datetime)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(chapter, attrs) do
    chapter
    |> cast(attrs, [
      :series_id,
      :chapter_key,
      :display_number,
      :title,
      :chapter_number,
      :sort_key,
      :source_url,
      :status,
      :retry_count,
      :last_error,
      :last_attempted_at,
      :locked_at,
      :published_at
    ])
    |> normalize_text_fields()
    |> validate_required([
      :series_id,
      :chapter_key,
      :display_number,
      :sort_key,
      :source_url,
      :status
    ])
    |> validate_inclusion(:status, Catalog.chapter_statuses())
    |> validate_number(:retry_count, greater_than_or_equal_to: 0)
    |> validate_length(:last_error, max: 2_000)
    |> check_constraint(:status, name: :series_chapters_status_check)
    |> foreign_key_constraint(:series_id)
    |> unique_constraint([:series_id, :chapter_key])
    |> unique_constraint(:source_url)
  end

  defp normalize_text_fields(changeset) do
    changeset
    |> update_change(:chapter_key, &trim/1)
    |> update_change(:display_number, &trim/1)
    |> update_change(:sort_key, &trim/1)
    |> update_change(:source_url, &trim/1)
  end

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value
end
