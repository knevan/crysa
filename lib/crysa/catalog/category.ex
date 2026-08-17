defmodule Crysa.Catalog.Category do
  @moduledoc """
  Normalized category/tag assigned to series.
  """

  use Ecto.Schema

  import Ecto.Changeset
  alias Crysa.Catalog.Normalization

  @type t :: %__MODULE__{}

  schema "categories" do
    field :name, :string
    field :normalized_name, :string

    timestamps(type: :utc_datetime)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(category, attrs) do
    category
    |> cast(attrs, [:name])
    |> update_change(:name, &trim/1)
    |> put_normalized_name()
    |> validate_required([:name, :normalized_name])
    |> validate_length(:name, min: 1, max: 80)
    |> unique_constraint(:normalized_name)
  end

  defp put_normalized_name(changeset) do
    put_change(
      changeset,
      :normalized_name,
      Normalization.normalized_name(get_field(changeset, :name))
    )
  end

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value
end
