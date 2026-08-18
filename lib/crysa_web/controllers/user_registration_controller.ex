defmodule CrysaWeb.UserRegistrationController do
  @moduledoc """
  Handles the registration HTTP action that creates the account and session.
  """

  use CrysaWeb, :controller

  alias Crysa.Accounts
  alias CrysaWeb.UserAuth

  plug :redirect_if_authenticated when action in [:create]

  defp redirect_if_authenticated(conn, _opts),
    do: CrysaWeb.UserAuth.redirect_if_user_is_authenticated(conn, [])

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"user" => user_params}) do
    case Accounts.register_user(user_params) do
      {:ok, user} ->
        conn
        |> put_flash(:info, "Welcome! Your account has been created.")
        |> UserAuth.log_in_user(user)

      {:error, _changeset} ->
        conn
        |> put_flash(:error, "Could not create the account. Please fix the errors and try again.")
        |> put_flash(:email, user_params["email"])
        |> put_flash(:username, user_params["username"])
        |> redirect(to: ~p"/users/register")
    end
  end

  def create(conn, _params) do
    conn
    |> put_flash(:error, "Could not create the account. Please fill in all fields.")
    |> redirect(to: ~p"/users/register")
  end
end
