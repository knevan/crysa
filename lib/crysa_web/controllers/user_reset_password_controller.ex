defmodule CrysaWeb.UserResetPasswordController do
  @moduledoc """
  Handles the reset-password submission for a one-time token.
  """

  use CrysaWeb, :controller

  alias Crysa.Accounts

  @spec update(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def update(conn, %{"token" => token, "user" => user_params}) do
    case Accounts.get_user_by_reset_password_token(token) do
      nil ->
        conn
        |> put_flash(:error, "Reset link is invalid or has expired.")
        |> redirect(to: ~p"/users/reset_password")

      user ->
        case Accounts.reset_user_password(user, user_params, token) do
          {:ok, _user} ->
            conn
            |> put_flash(:info, "Your password has been reset. You can now log in.")
            |> redirect(to: ~p"/users/log-in")

          {:error, _changeset} ->
            conn
            |> put_flash(:error, "Could not reset the password. Please try again.")
            |> redirect(to: ~p"/users/reset_password/#{token}")
        end
    end
  end

  def update(conn, _params) do
    conn
    |> put_flash(:error, "Reset link is invalid or has expired.")
    |> redirect(to: ~p"/users/reset_password")
  end
end
