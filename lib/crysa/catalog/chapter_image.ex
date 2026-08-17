defmodule Crysa.Catalog.ChapterImage do
  @moduledoc """
  Ordered image metadata for a chapter.
  """

  use Ecto.Schema

  import Ecto.Changeset
  alias Crysa.Catalog.Chapter

  @type t :: %__MODULE__{}

  schema "chapter_images" do
    field :image_order, :integer
    field :source_url, :string
    field :storage_key, :string
    field :width, :integer
    field :height, :integer
    field :byte_size, :integer

    belongs_to :chapter, Chapter

    timestamps(type: :utc_datetime)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(image, attrs) do
    image
    |> cast(attrs, [:chapter_id, :image_order, :source_url, :storage_key, :width, :height, :byte_size])
    |> validate_required([:chapter_id, :image_order])
    |> validate_number(:image_order, greater_than_or_equal_to: 0)
    |> validate_number(:width, greater_than: 0)
    |> validate_number(:height, greater_than: 0)
    |> validate_number(:byte_size, greater_than: 0)
    |> foreign_key_constraint(:chapter_id)
    |> unique_constraint([:chapter_id, :image_order])
  end
end
