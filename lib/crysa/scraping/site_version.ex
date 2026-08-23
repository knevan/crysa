defmodule Crysa.Scraping.SiteVersion do
  @moduledoc """
  Versioned scraping config document for a site.

  Lifecycle: `draft -> published -> superseded`. Only one published version
  may exist per site at a time (enforced by a partial unique index); workers
  resolve only published versions. Drafts are validated on save — a failed
  validation never touches the currently active published config.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Crysa.Scraping.Config
  alias Crysa.Scraping.Site

  @type t :: %__MODULE__{}

  @statuses ~w(draft published superseded)

  schema "scraping_site_versions" do
    field :version, :integer
    field :status, :string, default: "draft"
    field :config, :map
    field :checksum, :string
    field :published_at, :utc_datetime_usec

    belongs_to :site, Site
    belongs_to :created_by, Crysa.Accounts.User
    belongs_to :published_by, Crysa.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Builds a new draft version. `config_attrs` is the external (admin-supplied)
  document; it is fully validated through `Crysa.Scraping.Config.build/1`
  before being persisted as jsonb together with its checksum.
  """
  @spec draft_changeset(t(), map(), keyword()) :: Ecto.Changeset.t()
  def draft_changeset(version, attrs, opts \\ []) do
    version
    |> cast(attrs, [:site_id])
    |> put_next_version(Keyword.get(opts, :next_version))
    |> validate_required([:site_id])
    |> put_validated_config(config_attrs(normalize_attrs(attrs)))
    |> foreign_key_constraint(:site_id)
    |> unique_constraint([:site_id, :version])
  end

  defp normalize_attrs(nil), do: %{}

  defp normalize_attrs(attrs) when is_map(attrs),
    do: Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

  defp config_attrs(normalized), do: Map.get(normalized, "config")

  defp put_next_version(changeset, nil), do: changeset
  defp put_next_version(changeset, next), do: put_change(changeset, :version, next)

  defp put_validated_config(changeset, nil) do
    add_error(changeset, :config, "is required")
  end

  defp put_validated_config(changeset, config_attrs) when is_map(config_attrs) do
    case Config.build(config_attrs) do
      {:ok, config} ->
        changeset
        |> put_change(:config, Config.to_map(config))
        |> put_change(:checksum, Config.checksum(config))

      {:error, %Ecto.Changeset{} = config_changeset} ->
        traverse_config_errors(changeset, config_changeset)
    end
  end

  defp put_validated_config(changeset, _other) do
    add_error(changeset, :config, "must be a map")
  end

  # Surface nested config errors under the :config field so admin UIs get one
  # structured error map instead of an opaque "invalid" message.
  defp traverse_config_errors(changeset, config_changeset) do
    errors =
      config_changeset
      |> surface_errors()
      |> Jason.encode!()

    add_error(changeset, :config, "is invalid: " <> errors)
  end

  defp surface_errors(config_changeset) do
    config_changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  @doc "Marks this version as published."
  @spec publish_changeset(t(), keyword()) :: Ecto.Changeset.t()
  def publish_changeset(version, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    publisher_id = Keyword.get(opts, :published_by_id)

    change(version)
    |> put_change(:status, "published")
    |> put_change(:published_at, DateTime.truncate(now, :microsecond))
    |> put_change(:published_by_id, publisher_id)
    |> validate_inclusion(:status, @statuses)
  end

  @doc "Marks this version as superseded by a newer publication."
  @spec supersede_changeset(t()) :: Ecto.Changeset.t()
  def supersede_changeset(version) do
    change(version, status: "superseded")
  end
end
