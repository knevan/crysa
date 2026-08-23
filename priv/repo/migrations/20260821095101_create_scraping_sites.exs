defmodule Crysa.Repo.Migrations.CreateScrapingSites do
  use Ecto.Migration

  def change do
    # The two tables reference each other (sites -> current published
    # version, versions -> site), so the circular FK is added afterwards.
    create table(:scraping_sites) do
      add :host, :string, null: false
      add :name, :string, null: false
      add :enabled, :boolean, null: false, default: true
      add :current_published_version_id, :bigint

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:scraping_sites, [:host])

    create table(:scraping_site_versions) do
      add :site_id, references(:scraping_sites, on_delete: :delete_all), null: false
      add :version, :integer, null: false
      add :status, :string, null: false, default: "draft"
      add :config, :map, null: false
      add :checksum, :string, null: false
      add :created_by_id, references(:users, on_delete: :nilify_all)
      add :published_by_id, references(:users, on_delete: :nilify_all)
      add :published_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:scraping_site_versions, [:site_id, :version])
    create index(:scraping_site_versions, [:site_id, :status])

    create constraint(:scraping_site_versions, :scraping_site_versions_status_check,
             check: "status IN ('draft', 'published', 'superseded')"
           )

    # Only one published version per site at any time.
    create unique_index(:scraping_site_versions, [:site_id],
             name: :scraping_site_versions_single_published_index,
             where: "status = 'published'"
           )

    alter table(:scraping_sites) do
      modify :current_published_version_id,
             references(:scraping_site_versions, on_delete: :nilify_all),
             from: :bigint
    end
  end
end
