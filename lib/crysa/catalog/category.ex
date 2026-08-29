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

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(category, attrs) do
    category
    |> cast(attrs, [:name])
    |> update_change(:name, &normalize_display_name/1)
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

  # Normalizes to capitalized form per spec: "action" -> "Action", "action hero" -> "Action Hero".
  # Preserves internal whitespace exactly (so "Action   Comedy" stays with
  # 3 spaces) while capitalizing each word. Trims leading/trailing first.
  defp normalize_display_name(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.replace(~r/\S+/u, fn word ->
      word |> String.downcase() |> String.capitalize()
    end)
  end

  defp normalize_display_name(value), do: value
end
