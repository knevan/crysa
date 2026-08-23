defmodule Crysa.Scraping do
  @moduledoc """
  Scraping site configuration context.

  Owns database-backed scraping site configs with draft/publish/versioning so
  admins can safely edit configs without immediately affecting workers:

  * Drafts are fully validated (`Crysa.Scraping.Config`) before save.
  * Publishing is transactional: the previous published version becomes
    `superseded`, the target draft becomes `published`, and the site's
    `current_published_version_id` pointer moves atomically.
  * Workers resolve only published versions via `published_config_for_host/1`
    and capture the snapshot at job start; a failed validation or test scrape
    never touches the active config.

  The publish-time test scrape (validating selectors against sample HTML
  before `publish_version/3`) is delivered together with the admin UI in
  Phase 8.
  """

  import Ecto.Query

  alias Crysa.Repo
  alias Crysa.Scraping.{Config, ConfigCache, Site, SiteVersion}

  @type config_snapshot :: %{config: Config.t(), version: pos_integer()}

  # -- Sites -----------------------------------------------------------------

  @spec create_site(map()) :: {:ok, Site.t()} | {:error, Ecto.Changeset.t()}
  def create_site(attrs) do
    %Site{} |> Site.create_changeset(attrs) |> Repo.insert()
  end

  @spec update_site(Site.t(), map()) :: {:ok, Site.t()} | {:error, Ecto.Changeset.t()}
  def update_site(%Site{} = site, attrs) do
    with {:ok, updated} <- site |> Site.update_changeset(attrs) |> Repo.update() do
      ConfigCache.invalidate(site.host)
      {:ok, updated}
    end
  end

  @spec get_site(integer()) :: Site.t() | nil
  def get_site(id) when is_integer(id), do: Repo.get(Site, id)

  @spec get_site_by_host(String.t()) :: Site.t() | nil
  def get_site_by_host(host) when is_binary(host),
    do: Repo.get_by(Site, host: Site.normalize_host(host))

  @spec list_sites() :: [Site.t()]
  def list_sites do
    Repo.all(from(s in Site, order_by: s.host))
  end

  @doc "Lists enabled sites with their current published version preloaded."
  @spec list_enabled_sites_with_published_version() :: [Site.t()]
  def list_enabled_sites_with_published_version do
    Repo.all(
      from(s in Site,
        where: s.enabled == true,
        preload: [current_published_version: ^published_version_query()]
      )
    )
  end

  # -- Versions --------------------------------------------------------------

  @doc """
  Creates and validates a new draft version for `site`.

  The version number is `max(existing) + 1`. Config attributes are validated
  through `Config.build/1`; an invalid document returns errors without
  touching the currently published version.
  """
  @spec create_draft_version(Site.t() | integer(), map(), keyword()) ::
          {:ok, SiteVersion.t()} | {:error, Ecto.Changeset.t()}
  def create_draft_version(site_or_id, config_attrs, opts \\ [])

  def create_draft_version(%Site{id: site_id}, config_attrs, opts),
    do: create_draft_version(site_id, config_attrs, opts)

  def create_draft_version(site_id, config_attrs, opts) when is_integer(site_id) do
    next_version = next_version_number(site_id)

    changeset =
      %SiteVersion{}
      |> SiteVersion.draft_changeset(
        %{site_id: site_id, config: config_attrs},
        next_version: next_version
      )
      |> put_created_by(opts)
      |> validate_ajax_template_host(site_id)

    Repo.insert(changeset)
  end

  # SSRF guard: an ajax pagination template is a fetch target authored by the
  # admin, so it may only point at the site's own host (plan: restrict admin-
  # supplied fetch URLs to the configured host or an explicit allowlist).
  defp validate_ajax_template_host(changeset, site_id) do
    with %Site{host: host} = _site <- Repo.get(Site, site_id),
         {:ok, config} <- fetch_built_config(changeset),
         %{type: "ajax", url_template: template} when is_binary(template) <- config.pagination,
         %URI{host: template_host} when is_binary(template_host) <- URI.parse(template),
         false <- Site.normalize_host(template_host) == Site.normalize_host(host) do
      Ecto.Changeset.add_error(
        changeset,
        :config,
        "ajax url_template must point at the site's own host (#{host})"
      )
    else
      _ -> changeset
    end
  end

  defp fetch_built_config(changeset) do
    case Ecto.Changeset.get_change(changeset, :config) do
      nil -> {:error, :no_config}
      map -> Config.build(map)
    end
  end

  defp put_created_by(changeset, opts) do
    case Keyword.get(opts, :created_by_id) do
      nil -> changeset
      id -> Ecto.Changeset.put_change(changeset, :created_by_id, id)
    end
  end

  defp next_version_number(site_id) do
    max =
      Repo.one(
        from(v in SiteVersion,
          where: v.site_id == ^site_id,
          select: max(v.version)
        )
      ) || 0

    max + 1
  end

  @doc """
  Publishes a draft version transactionally.

  Steps inside one transaction:

    1. Lock and verify the target version belongs to `site` and is a draft.
    2. Supersede the currently published version (if any).
    3. Mark the target as published with publisher metadata.
    4. Move the site's `current_published_version_id` pointer.

  Returns `{:error, :not_a_draft}` or `{:error, :version_not_found}` when the
  target cannot be published; the previously published config stays active in
  every failure path.
  """
  @spec publish_version(Site.t() | integer(), integer(), keyword()) ::
          {:ok, %{site: Site.t(), version: SiteVersion.t()}}
          | {:error, :version_not_found | :not_a_draft | Ecto.Changeset.t()}
  def publish_version(site_or_id, version_id, opts \\ [])

  def publish_version(%Site{id: site_id}, version_id, opts),
    do: publish_version(site_id, version_id, opts)

  def publish_version(site_id, version_id, opts) when is_integer(site_id) do
    publisher_id = Keyword.get(opts, :published_by_id)

    result =
      Repo.transaction(fn ->
        version =
          Repo.one(
            from(v in SiteVersion,
              where: v.id == ^version_id and v.site_id == ^site_id,
              lock: "FOR UPDATE"
            )
          )

        cond do
          is_nil(version) ->
            Repo.rollback(:version_not_found)

          version.status != "draft" ->
            Repo.rollback(:not_a_draft)

          true ->
            supersede_current(site_id)
            published = publish_target(version, publisher_id)
            site = move_site_pointer!(site_id, published)
            %{site: site, version: published}
        end
      end)

    case result do
      {:ok, payload} ->
        ConfigCache.invalidate(Site.normalize_host(payload.site.host))
        {:ok, payload}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp supersede_current(site_id) do
    {_, _} =
      from(v in SiteVersion,
        where: v.site_id == ^site_id and v.status == "published"
      )
      |> Repo.update_all(set: [status: "superseded"])
  end

  defp publish_target(version, publisher_id) do
    version
    |> SiteVersion.publish_changeset(published_by_id: publisher_id)
    |> Repo.update!()
  end

  defp move_site_pointer!(site_id, published) do
    %Site{} = site = Repo.get!(Site, site_id)

    # change/2 must see a real diff (nil -> id); mutating the struct first
    # would make the update a silent no-op.
    %Site{} =
      updated =
      site
      |> Ecto.Changeset.change(current_published_version_id: published.id)
      |> Repo.update!()

    %Site{updated | current_published_version: published}
  end

  @spec get_version(integer()) :: SiteVersion.t() | nil
  def get_version(id) when is_integer(id), do: Repo.get(SiteVersion, id)

  @spec list_versions(Site.t() | integer()) :: [SiteVersion.t()]
  def list_versions(site_or_id)

  def list_versions(%Site{id: site_id}), do: list_versions(site_id)

  def list_versions(site_id) when is_integer(site_id) do
    Repo.all(from(v in SiteVersion, where: v.site_id == ^site_id, order_by: [desc: v.version]))
  end

  # -- Worker-facing snapshot resolution --------------------------------------

  defp published_version_query do
    from(v in SiteVersion, where: v.status == "published")
  end

  @doc """
  Resolves the published config snapshot for `host` (worker entry point).

  Returns `{:ok, %{config: %Config{}, version: n}}` or
  `{:error, :unknown_host | :no_published_config | :site_disabled}`. Callers
  must treat the returned struct as an immutable job-start snapshot.
  """
  @spec published_config_for_host(String.t()) ::
          {:ok, config_snapshot()}
          | {:error, :unknown_host | :no_published_config | :site_disabled}
  def published_config_for_host(host) when is_binary(host) do
    normalized = Site.normalize_host(host)

    # Read-through ETS cache: workers resolve a snapshot at every job start;
    # publishes and site updates invalidate the affected host.
    ConfigCache.get(normalized, fn -> load_published_config(normalized) end)
  end

  defp load_published_config(normalized) do
    site =
      Repo.one(
        from(s in Site,
          where: s.host == ^normalized,
          preload: [current_published_version: ^published_version_query()]
        )
      )

    cond do
      is_nil(site) ->
        {:error, :unknown_host}

      not site.enabled ->
        {:error, :site_disabled}

      match?(%SiteVersion{}, site.current_published_version) ->
        version = site.current_published_version
        {:ok, %{config: Config.from_map!(version.config), version: version.version}}

      true ->
        {:error, :no_published_config}
    end
  end
end
