defmodule Crysa.Audit.AdminAuditLog do
  @moduledoc """
  Schema for admin audit logs.

  Records every mutating admin/moderator action for traceability.
  Append-only, no updates. `metadata` is a bounded jsonb map with
  allowlisted keys; sensitive fields are never stored.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @allowed_actions ~w(
    category.create
    category.delete
    series.create
    series.delete
    series.archive
    series.unarchive
    series.update_schedule
    chapter.delete
    chapter.repair
    chapter.list
    user.update
    user.delete
    report.resolve
    report.reject
  )

  @allowed_target_types ~w(
    category
    series
    chapter
    user
    report
    system
  )

  schema "admin_audit_logs" do
    field :actor_role, :string
    field :actor_username, :string
    field :action, :string
    field :target_type, :string
    field :target_id, :integer
    field :target_identifier, :string
    field :metadata, :map, default: %{}
    field :ip_address, :string
    field :user_agent, :string

    belongs_to :actor, Crysa.Accounts.User, foreign_key: :actor_id, define_field: true

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc false
  def changeset(log, attrs) do
    log
    |> cast(attrs, [
      :actor_id,
      :actor_role,
      :actor_username,
      :action,
      :target_type,
      :target_id,
      :target_identifier,
      :metadata,
      :ip_address,
      :user_agent
    ])
    |> validate_required([:actor_role, :action, :target_type])
    |> validate_inclusion(:action, @allowed_actions)
    |> validate_inclusion(:target_type, @allowed_target_types)
    |> validate_length(:action, max: 50)
    |> validate_length(:target_type, max: 50)
    |> validate_length(:actor_role, max: 50)
    |> validate_length(:actor_username, max: 100)
    |> validate_length(:target_identifier, max: 500)
    |> validate_length(:ip_address, max: 45)
    |> validate_length(:user_agent, max: 500)
    |> validate_metadata()
    |> foreign_key_constraint(:actor_id)
  end

  @doc """
  Returns the list of allowed audit actions.
  """
  @spec allowed_actions() :: [String.t()]
  def allowed_actions, do: @allowed_actions

  @doc """
  Returns the list of allowed target types.
  """
  @spec allowed_target_types() :: [String.t()]
  def allowed_target_types, do: @allowed_target_types

  defp validate_metadata(changeset) do
    case get_change(changeset, :metadata) || get_field(changeset, :metadata) do
      nil ->
        changeset

      metadata when is_map(metadata) ->
        # Bound metadata size and key count to prevent bloat
        cond do
          map_size(metadata) > 20 ->
            add_error(changeset, :metadata, "too many keys (max 20)")

          byte_size(inspect(metadata)) > 5_000 ->
            add_error(changeset, :metadata, "too large (max 5KB)")

          true ->
            # Ensure keys and values are strings or primitives, no nested maps beyond 1 level
            if Enum.all?(metadata, fn {k, v} -> is_binary(k) and valid_metadata_value?(v) end) do
              changeset
            else
              add_error(changeset, :metadata, "contains invalid keys or values")
            end
        end

      _ ->
        add_error(changeset, :metadata, "must be a map")
    end
  end

  defp valid_metadata_value?(v) when is_binary(v), do: byte_size(v) <= 1_000
  defp valid_metadata_value?(v) when is_number(v), do: true
  defp valid_metadata_value?(v) when is_boolean(v), do: true
  defp valid_metadata_value?(nil), do: true
  defp valid_metadata_value?(v) when is_atom(v), do: true

  defp valid_metadata_value?(v) when is_list(v) do
    Enum.count_until(v, 21) <= 20 and Enum.all?(v, &valid_metadata_value?/1)
  end

  defp valid_metadata_value?(_), do: false
end
