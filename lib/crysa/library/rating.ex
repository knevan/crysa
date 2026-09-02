defmodule Crysa.Library.Rating do
  @moduledoc """
  User rating for a series.
  """

  use Ecto.Schema

  import Ecto.Changeset
  alias Crysa.Accounts.User
  alias Crysa.Catalog.Series

  @type t :: %__MODULE__{}

  schema "series_ratings" do
    field :rating, :float

    belongs_to :user, User
    belongs_to :series, Series

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(rating, attrs) do
    rating
    |> cast(attrs, [:user_id, :series_id, :rating])
    |> validate_required([:user_id, :series_id, :rating])
    |> validate_number(:rating, greater_than_or_equal_to: 1, less_than_or_equal_to: 5)
    |> validate_rating_step()
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:series_id)
    |> unique_constraint([:user_id, :series_id])
    |> check_constraint(:rating, name: :rating_between_1_and_5)
  end

  defp validate_rating_step(changeset) do
    validate_change(changeset, :rating, fn :rating, value ->
      # allow 0.5 increments: rating*2 must be integer 2..10
      # For out-of-range values let `validate_number` report the range error
      if value < 1 or value > 5 do
        []
      else
        scaled = value * 2

        if scaled == trunc(scaled) do
          []
        else
          [rating: "must be in 0.5 increments between 1 and 5"]
        end
      end
    end)
  end
end
