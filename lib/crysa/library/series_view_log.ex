defmodule Crysa.Library.SeriesViewLog do
  @moduledoc """
  Append-only series view event used for analytics and aggregation.
  """

  use Ecto.Schema

  import Ecto.Changeset
  alias Crysa.Accounts.User
  alias Crysa.Catalog.Series

  @type t :: %__MODULE__{}

  schema "series_view_log" do
    field :ip_hash, :binary
    field :user_agent_hash, :binary

    belongs_to :series, Series
    belongs_to :user, User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(view_log, attrs) do
    view_log
    |> cast(attrs, [:series_id, :user_id, :ip_hash, :user_agent_hash])
    |> validate_required([:series_id])
    |> validate_hash_size(:ip_hash)
    |> validate_hash_size(:user_agent_hash)
    |> foreign_key_constraint(:series_id)
    |> foreign_key_constraint(:user_id)
  end

  defp validate_hash_size(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      validate_binary_size(field, value, 16, 64)
    end)
  end

  defp validate_binary_size(field, value, min, max) when is_binary(value) do
    size = byte_size(value)

    if size >= min and size <= max do
      []
    else
      [{field, "must be between #{min} and #{max} bytes"}]
    end
  end

  defp validate_binary_size(field, _value, _min, _max), do: [{field, "must be a binary"}]
end
