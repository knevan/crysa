defmodule CrysaWeb.UserLoginLive do
  @moduledoc """
  Login page — shadcn-vue skin over native POST to `UserSessionController`.

  The form is a LiveVue island (`LoginForm.vue`) that renders `Card`/`Input`/`Button`
  but submits via a standard `<form method=\"post\">` so the session cookie is set
  via an HTTP response (`HttpOnly`, `Secure`, `SameSite`). The LiveView never
  handles the credentials itself and never calls `put_session`.
  """

  use CrysaWeb, :live_view

  on_mount {CrysaWeb.UserAuth, :mount_current_user}
  on_mount {CrysaWeb.UserAuth, :redirect_if_authenticated}

  @impl true
  def render(assigns) do
    ~H"""
    <.vue
      v-component="LoginForm"
      v-ssr={false}
      action={@action}
      csrfToken={@csrf_token}
      login={@login}
      error={@error}
    />
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    error =
      case Phoenix.Flash.get(socket.assigns.flash, :error) do
        msg when msg in ["Invalid email/username or password.", "Invalid credential"] ->
          "Invalid credential"

        other ->
          other
      end

    {:ok,
     assign(socket,
       action: ~p"/auth/login",
       csrf_token: Phoenix.Controller.get_csrf_token(),
       login: Phoenix.Flash.get(socket.assigns.flash, :login),
       error: error
     )}
  end
end
