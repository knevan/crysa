defmodule CrysaWeb.UserRegistrationLive do
  @moduledoc """
  Registration page — shadcn-vue skin over native POST to `UserRegistrationController`.

  Keeps the controller-POST flow so the session cookie is set via an HTTP
  response. The LiveView only supplies `action`, `csrf_token` and flash-backed
  initial values to the `RegistrationForm.vue` island.
  """

  use CrysaWeb, :live_view

  on_mount {CrysaWeb.UserAuth, :mount_current_user}
  on_mount {CrysaWeb.UserAuth, :redirect_if_authenticated}

  @impl true
  def render(assigns) do
    ~H"""
    <.vue
      v-component="RegistrationForm"
      v-ssr={false}
      action={@action}
      csrfToken={@csrf_token}
      email={@email}
      username={@username}
    />
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       action: ~p"/auth/register",
       csrf_token: Phoenix.Controller.get_csrf_token(),
       email: Phoenix.Flash.get(socket.assigns.flash, :email),
       username: Phoenix.Flash.get(socket.assigns.flash, :username)
     )}
  end
end
