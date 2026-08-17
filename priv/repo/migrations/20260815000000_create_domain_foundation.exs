defmodule Crysa.Repo.Migrations.CreateDomainFoundation do
  use Ecto.Migration

  def change do
    execute("CREATE EXTENSION IF NOT EXISTS pg_trgm", "DROP EXTENSION IF EXISTS pg_trgm")

    create table(:roles) do
      add :name, :string, null: false
      add :description, :text

      timestamps(type: :utc_datetime)
    end

    create unique_index(:roles, [:name])

    create table(:users) do
      add :email, :string, null: false
      add :username, :string, null: false
      add :password_hash, :string, null: false
      add :role_id, references(:roles, on_delete: :restrict), null: false
      add :active, :boolean, null: false, default: true
      add :confirmed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    execute(
      "CREATE UNIQUE INDEX users_lower_email_index ON users (lower(email))",
      "DROP INDEX IF EXISTS users_lower_email_index"
    )

    execute(
      "CREATE UNIQUE INDEX users_lower_username_index ON users (lower(username))",
      "DROP INDEX IF EXISTS users_lower_username_index"
    )

    create index(:users, [:role_id])

    create table(:user_profiles) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :display_name, :string
      add :avatar_url, :text

      timestamps(type: :utc_datetime)
    end

    create unique_index(:user_profiles, [:user_id])

    create table(:password_reset_tokens) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :token_digest, :binary, null: false
      add :expires_at, :utc_datetime, null: false
      add :used_at, :utc_datetime

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:password_reset_tokens, [:token_digest])
    create index(:password_reset_tokens, [:user_id])
    create index(:password_reset_tokens, [:expires_at])

    create table(:categories) do
      add :name, :string, null: false
      add :normalized_name, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:categories, [:normalized_name])

    create table(:authors) do
      add :name, :string, null: false
      add :normalized_name, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:authors, [:normalized_name])

    create table(:series) do
      add :title, :string, null: false
      add :slug, :string, null: false
      add :description, :text
      add :cover_url, :text
      add :source_url, :text, null: false
      add :publication_status, :string, null: false, default: "ongoing"
      add :processing_status, :string, null: false, default: "pending"
      add :chapter_count, :integer, null: false, default: 0
      add :bookmark_count, :integer, null: false, default: 0
      add :view_count, :integer, null: false, default: 0
      add :rating_count, :integer, null: false, default: 0
      add :rating_sum, :integer, null: false, default: 0
      add :next_check_at, :utc_datetime
      add :last_checked_at, :utc_datetime
      add :check_interval_minutes, :integer, null: false, default: 60
      add :last_chapter_at, :utc_datetime
      add :last_error, :text

      timestamps(type: :utc_datetime)
    end

    create unique_index(:series, [:slug])
    create unique_index(:series, [:source_url])
    create index(:series, [:publication_status])
    create index(:series, [:processing_status])
    create index(:series, [:next_check_at])

    execute(
      "CREATE INDEX series_title_trgm_index ON series USING gin (title gin_trgm_ops)",
      "DROP INDEX IF EXISTS series_title_trgm_index"
    )

    create table(:series_categories, primary_key: false) do
      add :series_id, references(:series, on_delete: :delete_all), null: false, primary_key: true

      add :category_id, references(:categories, on_delete: :restrict),
        null: false,
        primary_key: true
    end

    create index(:series_categories, [:category_id])

    create table(:series_authors, primary_key: false) do
      add :series_id, references(:series, on_delete: :delete_all), null: false, primary_key: true
      add :author_id, references(:authors, on_delete: :restrict), null: false, primary_key: true
    end

    create index(:series_authors, [:author_id])

    create table(:series_chapters) do
      add :series_id, references(:series, on_delete: :delete_all), null: false
      add :chapter_key, :string, null: false
      add :display_number, :string, null: false
      add :title, :string
      add :chapter_number, :decimal, precision: 12, scale: 3
      add :sort_key, :string, null: false
      add :source_url, :text, null: false
      add :status, :string, null: false, default: "pending"
      add :retry_count, :integer, null: false, default: 0
      add :last_error, :text
      add :last_attempted_at, :utc_datetime
      add :locked_at, :utc_datetime
      add :published_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:series_chapters, [:series_id, :chapter_key])
    create unique_index(:series_chapters, [:source_url])
    create index(:series_chapters, [:series_id, :sort_key])
    create index(:series_chapters, [:status])

    create table(:chapter_images) do
      add :chapter_id, references(:series_chapters, on_delete: :delete_all), null: false
      add :image_order, :integer, null: false
      add :source_url, :text
      add :storage_key, :text
      add :width, :integer
      add :height, :integer
      add :byte_size, :integer

      timestamps(type: :utc_datetime)
    end

    create unique_index(:chapter_images, [:chapter_id, :image_order])

    create table(:user_bookmarks) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :series_id, references(:series, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:user_bookmarks, [:user_id, :series_id])
    create index(:user_bookmarks, [:series_id])

    create table(:series_ratings) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :series_id, references(:series, on_delete: :delete_all), null: false
      add :rating, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:series_ratings, [:user_id, :series_id])
    create index(:series_ratings, [:series_id])

    create constraint(:series_ratings, :rating_between_1_and_5,
             check: "rating >= 1 AND rating <= 5"
           )

    create table(:series_view_log) do
      add :series_id, references(:series, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :nilify_all)
      add :ip_hash, :binary
      add :user_agent_hash, :binary

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:series_view_log, [:series_id, :inserted_at])
    create index(:series_view_log, [:inserted_at])

    create table(:comments) do
      add :user_id, references(:users, on_delete: :nilify_all)
      add :series_id, references(:series, on_delete: :delete_all)
      add :chapter_id, references(:series_chapters, on_delete: :delete_all)
      add :parent_id, references(:comments, on_delete: :restrict)
      add :body_markdown, :text, null: false
      add :body_html, :text, null: false
      add :deleted_at, :utc_datetime
      add :deleted_by_id, references(:users, on_delete: :nilify_all)
      add :vote_score, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:comments, [:series_id, :inserted_at])
    create index(:comments, [:chapter_id, :inserted_at])
    create index(:comments, [:parent_id])

    create constraint(:comments, :comments_single_target,
             check: "num_nonnulls(series_id, chapter_id) = 1"
           )

    create table(:comment_attachments) do
      add :comment_id, references(:comments, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :nilify_all)
      add :storage_key, :text, null: false
      add :content_type, :string, null: false
      add :byte_size, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:comment_attachments, [:comment_id])
    create index(:comment_attachments, [:user_id])

    create table(:comment_votes, primary_key: false) do
      add :user_id, references(:users, on_delete: :delete_all), null: false, primary_key: true

      add :comment_id, references(:comments, on_delete: :delete_all),
        null: false,
        primary_key: true

      add :vote, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:comment_votes, [:comment_id])
    create constraint(:comment_votes, :comment_votes_vote_value, check: "vote IN (-1, 1)")

    create table(:notifications) do
      add :recipient_id, references(:users, on_delete: :delete_all), null: false
      add :actor_id, references(:users, on_delete: :nilify_all)
      add :comment_id, references(:comments, on_delete: :delete_all)
      add :action, :string, null: false
      add :read_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:notifications, [:recipient_id, :read_at])
    create index(:notifications, [:comment_id])

    create table(:reports) do
      add :reporter_id, references(:users, on_delete: :nilify_all)
      add :chapter_id, references(:series_chapters, on_delete: :delete_all)
      add :comment_id, references(:comments, on_delete: :delete_all)
      add :reason, :string, null: false
      add :details, :text
      add :status, :string, null: false, default: "pending"
      add :resolved_by_id, references(:users, on_delete: :nilify_all)
      add :resolved_at, :utc_datetime
      add :resolution_note, :text

      timestamps(type: :utc_datetime)
    end

    create index(:reports, [:status, :inserted_at])
    create index(:reports, [:chapter_id])
    create index(:reports, [:comment_id])

    create constraint(:reports, :reports_single_target,
             check: "num_nonnulls(chapter_id, comment_id) = 1"
           )

    create constraint(:series, :series_publication_status_check,
             check: "publication_status IN ('ongoing', 'completed', 'hiatus', 'discontinued')"
           )

    create constraint(:series, :series_processing_status_check,
             check:
               "processing_status IN ('pending', 'processing', 'available', 'error', 'pending_deletion', 'deleting', 'deletion_failed')"
           )

    create constraint(:series_chapters, :series_chapters_status_check,
             check: "status IN ('pending', 'processing', 'available', 'no_images_found', 'error')"
           )

    create constraint(:reports, :reports_reason_check,
             check:
               "reason IN ('broken_image', 'wrong_chapter', 'duplicated_chapter', 'missing_image', 'missing_chapter', 'slow_loading', 'broken_text', 'toxic', 'racist', 'spam', 'other')"
           )

    create constraint(:reports, :reports_status_check,
             check: "status IN ('pending', 'resolved', 'rejected')"
           )

    create constraint(:notifications, :notifications_action_check,
             check: "action IN ('comment_reply', 'comment_upvote')"
           )

    create index(:notifications, [:recipient_id, :inserted_at],
             name: :notifications_unread_index,
             where: "read_at IS NULL"
           )
  end
end
