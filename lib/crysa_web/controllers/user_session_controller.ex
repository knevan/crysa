defmodule CrysaWeb.UserSessionController do
  @moduledoc """
  Handles the login and logout HTTP actions that set the session cookie.
  """

  use CrysaWeb, :controller

  alias Crysa.Accounts
  alias CrysaWeb.UserAuth

  plug :redirect_if_authenticated when action in [:create]

  defp redirect_if_authenticated(conn, _opts),
    do: CrysaWeb.UserAuth.redirect_if_user_is_authenticated(conn, [])

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"user" => %{"login" => login, "password" => password}})
      when is_binary(login) and is_binary(password) do
    case Accounts.authenticate_user(login, password) do
      {:ok, user} ->
        conn
        |> put_flash(:info, "Welcome back!")
        |> UserAuth.log_in_user(user)

      {:error, :inactive} ->
        conn
        |> put_flash(:error, "This account has been disabled.")
        |> put_flash(:login, login)
        |> redirect(to: ~p"/users/log-in")

      {:error, :invalid_credentials} ->
        conn
        |> put_flash(:error, "Invalid email/username or password.")
        |> put_flash(:login, login)
        |> redirect(to: ~p"/users/log-in")
    end
  end

  def create(conn, _params) do
    conn
    |> put_flash(:error, "Please enter your email/username and password.")
    |> redirect(to: ~p"/users/log-in")
  end

  @spec delete(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete(conn, _params) do
    conn
    |> put_flash(:info, "You have been logged out.")
    |> UserAuth.log_out_user()
  end
end
