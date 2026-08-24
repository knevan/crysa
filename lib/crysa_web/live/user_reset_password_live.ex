defmodule CrysaWeb.UserResetPasswordLive do
  @moduledoc """
  Reset password page backed by a one-time token.

  Invalid or expired tokens render a HEEX fallback. A valid token renders the
  `ResetPasswordForm.vue` island which POSTs natively to
  `UserResetPasswordController` so the flow stays controller-driven.
  """

  use CrysaWeb, :live_view

  alias Crysa.Accounts

  @impl true
  def render(%{invalid_token: true} = assigns) do
    ~H"""
    <div class="mx-auto max-w-md space-y-6 text-center">
      <.header>
        <p>Reset link invalid or expired</p>
        <:subtitle>
          Request a new link to reset your password.
        </:subtitle>
      </.header>

      <.link navigate={~p"/users/reset_password"} class="btn btn-primary">
        Request a new link
      </.link>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <.vue
      v-component="ResetPasswordForm"
      v-ssr={false}
      action={@action}
      csrfToken={@csrf_token}
      token={@token}
    />
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    if Accounts.get_user_by_reset_password_token(token) do
      {:ok,
       assign(socket,
         token: token,
         invalid_token: false,
         action: ~p"/users/reset_password/#{token}",
         csrf_token: Phoenix.Controller.get_csrf_token()
       )}
    else
      {:ok, assign(socket, invalid_token: true)}
    end
  end
end
