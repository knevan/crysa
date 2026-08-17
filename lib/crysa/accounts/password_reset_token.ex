defmodule Crysa.Accounts.PasswordResetToken do
  @moduledoc """
  Password reset token digest with expiry metadata.
  """

  use Ecto.Schema

  import Ecto.Changeset
  alias Crysa.Accounts.User

  @type t :: %__MODULE__{}

  schema "password_reset_tokens" do
    field :token_digest, :binary
    field :expires_at, :utc_datetime
    field :used_at, :utc_datetime

    belongs_to :user, User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(token, attrs) do
    token
    |> cast(attrs, [:user_id, :token_digest, :expires_at, :used_at])
    |> validate_required([:user_id, :token_digest, :expires_at])
    |> validate_digest_size(:token_digest, 32, 64)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:token_digest)
  end

  defp validate_digest_size(changeset, field, min, max) do
    validate_change(changeset, field, fn ^field, value ->
      validate_binary_size(field, value, min, max)
    end)
  end

  defp validate_binary_size(field, value, min, max) when is_binary(value) do
    size = byte_size(value)

    if size >= min and size <= max do
      []
    else
      [{field, "must be between #{min} and #{max} bytes"}]
    end
  end

  defp validate_binary_size(field, _value, _min, _max), do: [{field, "must be a binary"}]
end
