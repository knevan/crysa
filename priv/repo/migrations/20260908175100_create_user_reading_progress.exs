defmodule Crysa.Repo.Migrations.CreateUserReadingProgress do
  use Ecto.Migration

  def change do
    create table(:user_reading_progress) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :series_id, references(:series, on_delete: :delete_all), null: false
      add :last_chapter_id, references(:series_chapters, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:user_reading_progress, [:user_id, :series_id])
    create index(:user_reading_progress, [:series_id])
  end
end
