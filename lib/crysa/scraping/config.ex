defmodule Crysa.Scraping.Config do
  @moduledoc """
  Typed scraping configuration document stored as jsonb.

  One document per site per published version. Namespaced from day one into
  `selectors`, `chapter_order`, `pagination` and `rate_limit`; each namespace
  is validated by an embedded schema/changeset — jsonb is storage media only,
  never an excuse to skip validation ("typed at the edge, flexible at rest").

  Selector strings are validated conservatively here (charset allowlist,
  length bound, CSS parseability); their semantic correctness is proven at
  publish time through a test scrape against sample HTML, because Floki has
  no compiled-selector cache and silently ignores unknown selector tokens.

  ## Example

      %{
        "selectors" => %{
          "chapter_link" => "div.chapter-list a",
          "image_on_chapter_page" => "#reader img"
        },
        "chapter_order" => "desc",
        "pagination" => %{"type" => "query_param", "param" => "page", "max_pages" => 20},
        "rate_limit" => %{
          "request_delay_ms" => %{"min" => 1000, "max" => 3000},
          "image_delay_ms" => %{"min" => 500, "max" => 1500},
          "max_concurrent_requests" => 2
        }
      }
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Crysa.Scraping.Config.Selectors
  alias Crysa.Scraping.Config.{Pagination, RateLimit}

  @primary_key false
  @derive {Jason.Encoder, only: [:selectors, :chapter_order, :pagination, :rate_limit]}

  @chapter_orders ~w(asc desc)

  embedded_schema do
    embeds_one :selectors, Selectors, on_replace: :update

    field :chapter_order, :string, default: "desc"

    embeds_one :pagination, Pagination, on_replace: :update
    embeds_one :rate_limit, RateLimit, on_replace: :update
  end

  @doc """
  Builds a validated `%Config{}` from external (admin-supplied) attributes.

  Missing namespaces fall back to safe defaults defined by the embedded
  schemas. Returns `{:error, changeset}` when any namespace is invalid.
  """
  @spec build(map()) :: {:ok, %__MODULE__{}} | {:error, Ecto.Changeset.t()}
  def build(attrs) when is_map(attrs) do
    # Absent namespaces fall back to empty attr maps so the embedded schemas
    # apply their own safe defaults and the resulting struct is fully formed.
    attrs =
      attrs
      |> normalize_keys()
      |> Map.merge(
        %{"selectors" => %{}, "pagination" => %{}, "rate_limit" => %{}},
        fn _k, given, _default -> given end
      )

    %__MODULE__{}
    |> changeset(attrs)
    |> apply_action(:build)
  end

  @doc """
  Rebuilds a `%Config{}` from a previously persisted (trusted) map, e.g. a
  jsonb column value decoded by Postgrex. Raises on drift from the expected
  shape because persisted documents were already validated at save time.
  """
  @spec from_map!(map() | nil) :: %__MODULE__{}
  def from_map!(nil), do: build(%{}) |> elem(1)

  def from_map!(attrs) when is_map(attrs) do
    case build(normalize_keys(attrs)) do
      {:ok, config} ->
        config

      {:error, %Ecto.Changeset{} = changeset} ->
        raise ArgumentError,
              "invalid persisted scraping config: #{inspect(traverse_errors(changeset))}"
    end
  end

  def from_map!(_other), do: %__MODULE__{}

  @doc "Dumps the config to a plain JSON-compatible map (for jsonb storage)."
  @spec to_map(%__MODULE__{}) :: map()
  def to_map(%__MODULE__{} = config) do
    config
    |> Ecto.embedded_dump(:json)
    |> stringify_keys()
  end

  @doc "Computes a stable SHA-256 checksum over the canonical JSON encoding."
  @spec checksum(%__MODULE__{}) :: String.t()
  def checksum(%__MODULE__{} = config) do
    :crypto.hash(:sha256, Jason.encode!(to_map(config)))
    |> Base.encode16(case: :lower)
  end

  defp changeset(config, attrs) do
    config
    |> cast(attrs, [:chapter_order])
    |> validate_inclusion(:chapter_order, @chapter_orders)
    |> cast_embed(:selectors, with: &Selectors.changeset/2, required: true)
    |> cast_embed(:pagination, with: &Pagination.changeset/2)
    |> cast_embed(:rate_limit, with: &RateLimit.changeset/2)
  end

  # -- helpers ---------------------------------------------------------------

  defp normalize_keys(attrs) when is_map(attrs) do
    Map.new(attrs, fn {k, v} -> {to_string(k), normalize_value(v)} end)
  end

  defp normalize_value(%{} = value), do: normalize_keys(value)
  defp normalize_value(value), do: value

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), maybe_stringify(v)}
      {k, v} -> {k, maybe_stringify(v)}
    end)
  end

  defp maybe_stringify(v) when is_map(v), do: stringify_keys(v)
  defp maybe_stringify(v), do: v

  defp traverse_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
