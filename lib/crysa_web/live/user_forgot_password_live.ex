defmodule CrysaWeb.UserForgotPasswordLive do
  @moduledoc """
  Forgot password page — shadcn-vue skin over native POST to `UserForgotPasswordController`.
  """

  use CrysaWeb, :live_view

  @impl true
  def render(assigns) do
    ~H"""
    <.vue
      v-component="ForgotPasswordForm"
      v-ssr={false}
      action={@action}
      csrfToken={@csrf_token}
    />
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       action: ~p"/users/reset_password",
       csrf_token: Phoenix.Controller.get_csrf_token()
     )}
  end
end
