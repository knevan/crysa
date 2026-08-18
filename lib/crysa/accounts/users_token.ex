defmodule Crysa.Accounts.UsersToken do
  @moduledoc """
  Persisted user session tokens.
  """

  use Ecto.Schema

  import Ecto.Query

  alias Crysa.Accounts.{User, UsersToken}

  @rand_size 32
  @session_validity_in_days 14

  @type t :: %__MODULE__{}

  schema "users_tokens" do
    field :token, :binary
    field :context, :string
    field :sent_to, :string
    field :authenticated_at, :utc_datetime_usec

    belongs_to :user, User

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc """
  Builds a session token that is stored in a signed place, such as the
  session cookie. Because the token is signed by Phoenix, it does not need
  to be hashed before being persisted.
  """
  @spec build_session_token(User.t()) :: {binary(), t()}
  def build_session_token(user) do
    token = :crypto.strong_rand_bytes(@rand_size)
    now = DateTime.utc_now()

    {token,
     %UsersToken{
       token: token,
       context: "session",
       user_id: user.id,
       authenticated_at: now
     }}
  end

  @doc """
  Returns the query that looks up the user owning the given session token.

  The token is valid when it matches the persisted value and was inserted
  within the session validity window.
  """
  @spec verify_session_token_query(binary()) :: {:ok, Ecto.Query.t()}
  def verify_session_token_query(token) when is_binary(token) do
    query =
      from token in by_token_and_context_query(token, "session"),
        join: user in assoc(token, :user),
        where: token.inserted_at > ago(@session_validity_in_days, "day"),
        select: user

    {:ok, query}
  end

  @doc """
  Returns the query that looks up the session token belonging to the user.
  """
  @spec user_sessions_query(User.t()) :: Ecto.Query.t()
  def user_sessions_query(user) do
    from(token in UsersToken, where: token.user_id == ^user.id and token.context == "session")
  end

  defp by_token_and_context_query(token, context) do
    from(UsersToken, where: [token: ^token, context: ^context])
  end
end
