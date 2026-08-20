defmodule Crysa.Comments.Attachment do
  @moduledoc """
  Stored attachment metadata for a comment.

  Attachments are validated strictly: allowlisted content types, bounded
  byte size (max 5 MiB), and storage keys that are unguessable and free of
  path traversal. Ownership is checked at the context layer.
  """

  use Ecto.Schema

  import Ecto.Changeset
  alias Crysa.Accounts.User
  alias Crysa.Comments.Comment

  @allowed_content_types ~w(image/jpeg image/png image/webp image/gif image/jpg)
  @max_byte_size 5 * 1024 * 1024
  @min_byte_size 1

  @type t :: %__MODULE__{}

  schema "comment_attachments" do
    field :storage_key, :string
    field :content_type, :string
    field :byte_size, :integer

    belongs_to :comment, Comment
    belongs_to :user, User

    timestamps(type: :utc_datetime_usec)
  end

  @spec allowed_content_types() :: [String.t()]
  def allowed_content_types, do: @allowed_content_types

  @spec max_byte_size() :: pos_integer()
  def max_byte_size, do: @max_byte_size

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(attachment, attrs) do
    attachment
    |> cast(attrs, [:comment_id, :user_id, :storage_key, :content_type, :byte_size])
    |> validate_required([:comment_id, :storage_key, :content_type, :byte_size])
    |> validate_length(:storage_key, min: 1, max: 1_024)
    |> validate_inclusion(:content_type, @allowed_content_types,
      message: "is not an allowed image type"
    )
    |> validate_length(:content_type, min: 3, max: 120)
    |> validate_number(:byte_size,
      greater_than_or_equal_to: @min_byte_size,
      less_than_or_equal_to: @max_byte_size,
      message: "must be between 1 and 5242880 bytes"
    )
    |> validate_storage_key()
    |> foreign_key_constraint(:comment_id)
    |> foreign_key_constraint(:user_id)
  end

  defp validate_storage_key(changeset) do
    validate_change(changeset, :storage_key, fn :storage_key, value ->
      cond do
        String.contains?(value, "..") ->
          [storage_key: "must not contain path traversal"]

        String.contains?(value, "\\") ->
          [storage_key: "must not contain backslashes"]

        String.starts_with?(value, "/") ->
          [storage_key: "must be relative"]

        not Regex.match?(~r/\A[a-zA-Z0-9_\-\/\.]+\z/, value) ->
          [storage_key: "contains invalid characters"]

        true ->
          []
      end
    end)
  end
end
