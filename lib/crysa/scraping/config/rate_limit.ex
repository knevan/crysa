defmodule Crysa.Scraping.Config.RateLimit do
  @moduledoc """
  Outbound throttling namespace of a scraping config document.

  Configuration level is per-site only. Values are bounded by absolute
  floors/ceilings validated here; safe defaults live in
  `Crysa.Scraping.Throttle` and apply when a namespace is absent. Enforcement
  is centralized in the per-host gate in the fetcher layer — never scattered
  `Process.sleep/1` calls at call sites.

  Random jitter within min/max ranges is applied at enforcement time so
  outbound traffic does not look metronomic.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false

  @concurrency_cap 8

  defmodule DelayRange do
    @moduledoc false

    use Ecto.Schema

    import Ecto.Changeset

    @primary_key false

    @floor_ms 100
    @ceiling_ms 60_000

    embedded_schema do
      field :min, :integer
      field :max, :integer
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(range, attrs) do
      range
      |> cast(attrs, [:min, :max])
      |> validate_required([:min, :max])
      |> validate_number(:min,
        greater_than_or_equal_to: @floor_ms,
        less_than_or_equal_to: @ceiling_ms
      )
      |> validate_number(:max,
        greater_than_or_equal_to: @floor_ms,
        less_than_or_equal_to: @ceiling_ms
      )
      |> validate_min_max_order()
    end

    defp validate_min_max_order(changeset) do
      min = get_field(changeset, :min)
      max = get_field(changeset, :max)

      if is_integer(min) and is_integer(max) and min > max do
        add_error(changeset, :max, "must be greater than or equal to min")
      else
        changeset
      end
    end

    @doc false
    def floor_ms, do: @floor_ms

    @doc false
    def ceiling_ms, do: @ceiling_ms
  end

  embedded_schema do
    embeds_one :request_delay_ms, DelayRange, on_replace: :update
    embeds_one :image_delay_ms, DelayRange, on_replace: :update
    field :max_concurrent_requests, :integer
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(rate_limit, attrs) do
    rate_limit
    |> cast(attrs, [:max_concurrent_requests])
    |> cast_embed(:request_delay_ms, with: &DelayRange.changeset/2)
    |> cast_embed(:image_delay_ms, with: &DelayRange.changeset/2)
    |> validate_number(:max_concurrent_requests,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: @concurrency_cap
    )
  end

  @doc "Absolute bounds exposed for admin UI hints and tests."
  @spec bounds() :: %{
          delay_floor_ms: pos_integer(),
          delay_ceiling_ms: pos_integer(),
          concurrency_cap: pos_integer()
        }
  def bounds do
    %{
      delay_floor_ms: DelayRange.floor_ms(),
      delay_ceiling_ms: DelayRange.ceiling_ms(),
      concurrency_cap: @concurrency_cap
    }
  end
end
