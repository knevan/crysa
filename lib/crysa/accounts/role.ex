defmodule Crysa.Accounts.Role do
  @moduledoc """
  User role used by authorization policies.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Crysa.Accounts

  @type t :: %__MODULE__{}

  schema "roles" do
    field :name, :string
    field :description, :string

    timestamps(type: :utc_datetime)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(role, attrs) do
    role
    |> cast(attrs, [:name, :description])
    |> update_change(:name, &normalize/1)
    |> validate_required([:name])
    |> validate_inclusion(:name, Accounts.role_names())
    |> unique_constraint(:name)
  end

  defp normalize(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize(value), do: value
end
