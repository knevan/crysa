defmodule CrysaWeb.UserForgotPasswordController do
  @moduledoc """
  Handles the forgot-password request: creates a reset token and emails it.
  """

  use CrysaWeb, :controller

  alias Crysa.Accounts
  alias Crysa.Accounts.UserEmail

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"user" => %{"email" => email}}) when is_binary(email) do
    email = String.trim(email)

    if user = Accounts.get_user_by_email(email) do
      with {:ok, token} <- Accounts.create_reset_token(user) do
        UserEmail.deliver_reset_password_instructions(
          user,
          url(~p"/users/reset_password/#{token}")
        )
      end
    end

    conn
    |> put_flash(
      :info,
      "If your email is in our system, you will receive reset instructions shortly."
    )
    |> redirect(to: ~p"/users/log-in")
  end

  def create(conn, _params) do
    conn
    |> put_flash(
      :info,
      "If your email is in our system, you will receive reset instructions shortly."
    )
    |> redirect(to: ~p"/users/log-in")
  end
end
