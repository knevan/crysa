defmodule CrysaWeb.UserSettingsLive do
  @moduledoc """
  Account settings page: password change.
  """

  use CrysaWeb, :live_view

  alias Crysa.Accounts

  on_mount {CrysaWeb.UserAuth, :mount_current_user}
  on_mount {CrysaWeb.UserAuth, :require_authenticated}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-md space-y-6">
      <div class="text-center">
        <.header>
          <p>Account settings</p>
          <:subtitle>Update your password.</:subtitle>
        </.header>
      </div>

      <.simple_form
        for={@password_form}
        id="password_form"
        phx-submit="update_password"
      >
        <.input
          field={@password_form[:current_password]}
          type="password"
          label="Current password"
          required
        />
        <.input
          field={@password_form[:password]}
          type="password"
          label="New password"
          required
        />
        <.input
          field={@password_form[:password_confirmation]}
          type="password"
          label="Confirm new password"
          required
        />

        <:actions>
          <.button class="w-full">Change password</.button>
        </:actions>
      </.simple_form>

      <div class="text-center text-sm">
        <.link navigate={~p"/users/profile"} class="link link-primary">
          Edit your profile
        </.link>
      </div>
    </div>
    """
  end

  @impl true
  def mount(_params, session, socket) do
    user = socket.assigns.current_user

    {:ok,
     assign(socket,
       password_form: to_form(Accounts.change_user_password(user)),
       session_token: session["user_token"]
     )}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("update_password", %{"user" => params}, socket) do
    user = socket.assigns.current_user

    case Accounts.update_user_password(user, params, keep_session: socket.assigns.session_token) do
      {:ok, _user} ->
        {:noreply,
         socket
         |> put_flash(:info, "Password updated successfully")
         |> push_patch(to: ~p"/users/settings")}

      {:error, changeset} ->
        {:noreply, assign(socket, password_form: to_form(changeset))}
    end
  end
end
