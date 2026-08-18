defmodule CrysaWeb.UserLoginLive do
  @moduledoc """
  Login page.
  """

  use CrysaWeb, :live_view

  on_mount {CrysaWeb.UserAuth, :mount_current_user}
  on_mount {CrysaWeb.UserAuth, :redirect_if_authenticated}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-md space-y-6">
      <div class="text-center">
        <.header>
          <p>Log in</p>
          <:subtitle>
            Don't have an account? <.link
              navigate={~p"/users/register"}
              class="font-semibold text-primary hover:underline"
              phx-no-format
            >
              Sign up
            </.link> for an account now.
          </:subtitle>
        </.header>
      </div>

      <.simple_form
        for={@form}
        id="login_form"
        action={~p"/users/log-in"}
        phx-submit="submit"
        phx-trigger-action={@trigger_submit}
      >
        <.input
          field={@form[:login]}
          label="Email or username"
          autocomplete="username"
          required
        />
        <.input
          field={@form[:password]}
          type="password"
          label="Password"
          autocomplete="current-password"
          required
        />

        <div class="text-sm">
          <.link href={~p"/users/reset_password"} class="link link-primary">
            Forgot your password?
          </.link>
        </div>

        <:actions>
          <.button class="w-full">Log in</.button>
        </:actions>
      </.simple_form>
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    login = Phoenix.Flash.get(socket.assigns.flash, :login)

    {:ok,
     assign(socket,
       form: to_form(%{"login" => login}, as: "user"),
       trigger_submit: false
     )}
  end

  @impl true
  def handle_event("submit", _params, socket) do
    {:noreply, assign(socket, :trigger_submit, true)}
  end
end
