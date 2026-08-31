defmodule Crysa.Repo.Migrations.AddAdminAuditLogs do
  use Ecto.Migration

  def change do
    create table(:admin_audit_logs) do
      add :actor_id, references(:users, on_delete: :nilify_all)
      add :actor_role, :string, null: false
      add :actor_username, :string
      add :action, :string, null: false
      add :target_type, :string, null: false
      add :target_id, :bigint
      add :target_identifier, :text
      add :metadata, :map, default: %{}
      add :ip_address, :string
      add :user_agent, :text

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:admin_audit_logs, [:actor_id])
    create index(:admin_audit_logs, [:action])
    create index(:admin_audit_logs, [:target_type])
    create index(:admin_audit_logs, [:target_id])
    create index(:admin_audit_logs, [:inserted_at])
    create index(:admin_audit_logs, [:actor_id, :inserted_at])
    create index(:admin_audit_logs, [:action, :inserted_at])

    create constraint(:admin_audit_logs, :action_must_be_present,
             check: "char_length(action) > 0"
           )

    create constraint(:admin_audit_logs, :target_type_must_be_present,
             check: "char_length(target_type) > 0"
           )
  end
end
