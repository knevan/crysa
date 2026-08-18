defmodule CrysaWeb.UserForgotPasswordLive do
  @moduledoc """
  Forgot password page.
  """

  use CrysaWeb, :live_view

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-md space-y-6">
      <div class="text-center">
        <.header>
          <p>Reset your password</p>
          <:subtitle>
            Enter your account email and we'll send you a reset link.
          </:subtitle>
        </.header>
      </div>

      <.simple_form
        for={@form}
        id="forgot_password_form"
        action={~p"/users/reset_password"}
        phx-submit="submit"
        phx-trigger-action={@trigger_submit}
      >
        <.input
          field={@form[:email]}
          type="email"
          label="Email"
          autocomplete="email"
          required
        />

        <:actions>
          <.button class="w-full">Send reset instructions</.button>
        </:actions>
      </.simple_form>

      <div class="text-center text-sm">
        <.link navigate={~p"/users/log-in"} class="link link-primary">
          Back to log in
        </.link>
      </div>
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, form: to_form(%{}, as: "user"), trigger_submit: false)}
  end

  @impl true
  def handle_event("submit", _params, socket) do
    {:noreply, assign(socket, :trigger_submit, true)}
  end
end
