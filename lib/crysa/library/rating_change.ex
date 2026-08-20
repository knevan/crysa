defmodule Crysa.Library.RatingChange do
  @moduledoc """
  Result of a rating upsert.

  Describes whether the rating was created, updated, or left unchanged, plus
  the previous value. LiveView/Vue clients use this to reconcile optimistic
  rating UI against the authoritative server state.
  """

  @enforce_keys [:rating]
  defstruct [:rating, :created?, :previous_rating]

  @typedoc "The persisted rating and how the upsert changed it."
  @type t :: %__MODULE__{
          rating: Crysa.Library.Rating.t() | nil,
          created?: boolean(),
          previous_rating: integer() | nil
        }
end
