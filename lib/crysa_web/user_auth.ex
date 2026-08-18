defmodule CrysaWeb.UserAuth do
  @moduledoc """
  Handles authentication and authorization for controllers and LiveViews.

  The current user is loaded once per request from the session token and
  stored in `conn.assigns[:current_user]` / `socket.assigns[:current_user]`
  with the role preloaded. Role checks return `403 Forbidden` for controller
  requests and redirect with an error flash for LiveViews.
  """

  use CrysaWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  alias Crysa.Accounts
  alias CrysaWeb.Endpoint

  @moderator_roles ~w(superadmin admin moderator)
  @admin_roles ~w(superadmin admin)

  @doc "Logs the user in and issues a new session token."
  @spec log_in_user(Plug.Conn.t(), Crysa.Accounts.User.t()) :: Plug.Conn.t()
  def log_in_user(conn, user) do
    return_to = get_session(conn, :user_return_to)
    token = Accounts.generate_user_session_token(user)

    conn
    |> renew_session()
    |> put_token_in_session(token)
    |> redirect(to: return_to || signed_in_path(user))
  end

  @doc "Logs the user out, deletes the session token, and clears the session."
  @spec log_out_user(Plug.Conn.t()) :: Plug.Conn.t()
  def log_out_user(conn) do
    token = get_session(conn, :user_token)
    if token, do: Accounts.delete_user_session_token(token)

    if live_socket_id = get_session(conn, :live_socket_id) do
      Endpoint.broadcast(live_socket_id, "disconnect", %{})
    end

    conn
    |> renew_session()
    |> redirect(to: ~p"/")
  end

  @doc """
  Loads the current user from the session token and stores it in assigns.
  """
  @spec fetch_current_user(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def fetch_current_user(conn, _opts) do
    if token = get_session(conn, :user_token) do
      case Accounts.get_user_by_session_token(token) do
        %{} = user -> assign(conn, :current_user, user)
        nil -> assign(conn, :current_user, nil)
      end
    else
      assign(conn, :current_user, nil)
    end
  end

  @doc "Redirects authenticated users away from login-only pages."
  @spec redirect_if_user_is_authenticated(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def redirect_if_user_is_authenticated(conn, _opts) do
    if current_user(conn) do
      conn
      |> redirect(to: signed_in_path(conn))
      |> halt()
    else
      conn
    end
  end

  @doc "Requires an authenticated user, redirecting to login otherwise."
  @spec require_authenticated_user(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def require_authenticated_user(conn, _opts) do
    if current_user(conn) do
      conn
    else
      conn
      |> put_flash(:error, "You must log in to access this page.")
      |> maybe_store_return_to()
      |> redirect(to: ~p"/users/log-in")
      |> halt()
    end
  end

  @doc """
  Requires the user to hold one of the given role names.

  Returns `403 Forbidden` on authorization failures.
  """
  @spec require_role(Plug.Conn.t(), [String.t()]) :: Plug.Conn.t()
  def require_role(conn, allowed_roles) do
    role = conn |> current_user() |> role_name()

    if is_binary(role) and role in allowed_roles do
      conn
    else
      conn
      |> put_status(403)
      |> put_view(CrysaWeb.ErrorHTML)
      |> render("403.html")
      |> halt()
    end
  end

  @doc "Requires moderator access (superadmin, admin, or moderator)."
  @spec require_moderator(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def require_moderator(conn, _opts), do: require_role(conn, @moderator_roles)

  @doc "Requires admin access (superadmin or admin)."
  @spec require_admin(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def require_admin(conn, _opts), do: require_role(conn, @admin_roles)

  @doc "Returns the current user from the connection assigns."
  @spec current_user(Plug.Conn.t()) :: Crysa.Accounts.User.t() | nil
  def current_user(conn), do: conn.assigns[:current_user]

  ## LiveView mount helpers

  @doc """
  `on_mount` callbacks used by LiveViews.

    * `:mount_current_user` - loads the current user into socket assigns.
    * `:require_authenticated` - requires an authenticated user.
    * `:redirect_if_authenticated` - redirects authenticated users away.
    * `:require_moderator` - requires a moderator-level role.
    * `:require_admin` - requires an admin-level role.
  """
  def on_mount(:mount_current_user, _params, session, socket) do
    {:cont, mount_current_user(socket, session)}
  end

  def on_mount(:require_authenticated, _params, session, socket) do
    socket = mount_current_user(socket, session)

    if socket.assigns[:current_user] do
      {:cont, socket}
    else
      socket =
        socket
        |> Phoenix.LiveView.put_flash(:error, "You must log in to access this page.")
        |> Phoenix.LiveView.redirect(to: ~p"/users/log-in")

      {:halt, socket}
    end
  end

  def on_mount(:redirect_if_authenticated, _params, session, socket) do
    socket = mount_current_user(socket, session)

    if socket.assigns[:current_user] do
      {:halt, Phoenix.LiveView.redirect(socket, to: signed_in_path(socket))}
    else
      {:cont, socket}
    end
  end

  def on_mount(:require_moderator, _params, session, socket) do
    socket = mount_current_user(socket, session)
    require_role_mount(socket, @moderator_roles)
  end

  def on_mount(:require_admin, _params, session, socket) do
    socket = mount_current_user(socket, session)
    require_role_mount(socket, @admin_roles)
  end

  defp require_role_mount(socket, allowed_roles) do
    role = socket.assigns[:current_user] |> role_name()

    if is_binary(role) and role in allowed_roles do
      {:cont, socket}
    else
      socket =
        socket
        |> Phoenix.LiveView.put_flash(:error, "You are not authorized to access this page.")
        |> Phoenix.LiveView.redirect(to: ~p"/")

      {:halt, socket}
    end
  end

  defp mount_current_user(socket, session) do
    Phoenix.Component.assign_new(socket, :current_user, fn ->
      if token = session["user_token"] do
        Accounts.get_user_by_session_token(token)
      end
    end)
  end

  defp role_name(%Crysa.Accounts.User{role: %{name: name}}), do: name
  defp role_name(_), do: nil

  @doc "Returns the path to redirect to after log in."
  def signed_in_path(%Crysa.Accounts.User{}), do: ~p"/users/settings"

  def signed_in_path(assigns) do
    case current_user(assigns) do
      %Crysa.Accounts.User{} -> ~p"/users/settings"
      nil -> ~p"/"
    end
  end

  defp renew_session(conn) do
    delete_csrf_token()

    conn
    |> configure_session(renew: true)
    |> clear_session()
  end

  defp put_token_in_session(conn, token) do
    conn
    |> put_session(:user_token, token)
    |> put_session(:live_socket_id, user_session_topic(token))
  end

  defp user_session_topic(token), do: "users_sessions:#{Base.url_encode64(token)}"

  defp maybe_store_return_to(%{method: "GET"} = conn) do
    put_session(conn, :user_return_to, current_path(conn))
  end

  defp maybe_store_return_to(conn), do: conn
end
