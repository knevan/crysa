defmodule CrysaWeb.UserResetPasswordLive do
  @moduledoc """
  Reset password page backed by a one-time token.
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
    <div class="mx-auto max-w-md space-y-6">
      <div class="text-center">
        <.header>
          <p>Choose a new password</p>
        </.header>
      </div>

      <.simple_form
        for={@form}
        id="reset_password_form"
        action={~p"/users/reset_password/#{@token}"}
        phx-submit="submit"
        phx-trigger-action={@trigger_submit}
      >
        <.input field={@form[:password]} type="password" label="New password" required />
        <.input
          field={@form[:password_confirmation]}
          type="password"
          label="Confirm new password"
          required
        />

        <:actions>
          <.button class="w-full">Reset password</.button>
        </:actions>
      </.simple_form>
    </div>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    if Accounts.get_user_by_reset_password_token(token) do
      {:ok,
       assign(socket,
         token: token,
         invalid_token: false,
         form: to_form(%{}, as: "user"),
         trigger_submit: false
       )}
    else
      {:ok, assign(socket, invalid_token: true)}
    end
  end

  @impl true
  def handle_event("submit", _params, socket) do
    {:noreply, assign(socket, :trigger_submit, true)}
  end
end
