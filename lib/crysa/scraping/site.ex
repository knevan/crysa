defmodule Crysa.Scraping.Site do
  @moduledoc """
  Stable scraping site identity: host, display name, enabled flag and a
  pointer to the currently published config version.

  Workers never read draft versions; they resolve the published snapshot via
  `Crysa.Scraping.published_config_for_host/1`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Crysa.Scraping.SiteVersion

  @type t :: %__MODULE__{}

  @host_regex ~r/\A[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+\z/

  schema "scraping_sites" do
    field :host, :string
    field :name, :string
    field :enabled, :boolean, default: true

    belongs_to :current_published_version, SiteVersion

    has_many :versions, SiteVersion

    timestamps(type: :utc_datetime_usec)
  end

  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(site, attrs) do
    site
    |> cast(attrs, [:host, :name, :enabled])
    |> validate_required([:host, :name])
    |> normalize_host_change()
    |> validate_host_format()
    |> validate_length(:name, max: 200)
    |> unique_constraint(:host)
  end

  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(site, attrs) do
    site
    |> cast(attrs, [:name, :enabled])
    |> validate_required([:name])
    |> validate_length(:name, max: 200)
  end

  @doc "Normalizes a host for comparison/storage (trim + downcase)."
  @spec normalize_host(String.t()) :: String.t()
  def normalize_host(host) when is_binary(host), do: host |> String.trim() |> String.downcase()

  @doc "Validates host shape (public so the context can pre-normalize input)."
  @spec valid_host?(String.t()) :: boolean()
  def valid_host?(host) when is_binary(host), do: Regex.match?(@host_regex, host)
  def valid_host?(_), do: false

  defp normalize_host_change(changeset) do
    update_change(changeset, :host, &normalize_host/1)
  end

  defp validate_host_format(changeset) do
    case get_field(changeset, :host) do
      nil ->
        changeset

      host ->
        if valid_host?(host),
          do: changeset,
          else: add_error(changeset, :host, "is not a valid hostname")
    end
  end
end
