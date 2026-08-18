defmodule CrysaWeb.UserRegistrationLive do
  @moduledoc """
  Registration page.
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
          <p>Create your account</p>
          <:subtitle>
            Already have an account? <.link
              navigate={~p"/users/log-in"}
              class="font-semibold text-primary hover:underline"
              phx-no-format
            >
              Log in
            </.link>
          </:subtitle>
        </.header>
      </div>

      <.simple_form
        for={@form}
        id="registration_form"
        action={~p"/users/register"}
        phx-submit="submit"
        phx-trigger-action={@trigger_submit}
      >
        <.input field={@form[:email]} type="email" label="Email" required />
        <.input field={@form[:username]} label="Username" required />
        <.input field={@form[:password]} type="password" label="Password" required />
        <.input
          field={@form[:password_confirmation]}
          type="password"
          label="Confirm password"
          required
        />

        <p class="text-xs opacity-70">
          Password must be at least 12 characters and contain letters and numbers.
        </p>

        <:actions>
          <.button class="w-full">Create account</.button>
        </:actions>
      </.simple_form>
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    form =
      to_form(
        %{
          "email" => Phoenix.Flash.get(socket.assigns.flash, :email),
          "username" => Phoenix.Flash.get(socket.assigns.flash, :username)
        },
        as: "user"
      )

    {:ok, assign(socket, form: form, trigger_submit: false)}
  end

  @impl true
  def handle_event("submit", _params, socket) do
    {:noreply, assign(socket, :trigger_submit, true)}
  end
end
