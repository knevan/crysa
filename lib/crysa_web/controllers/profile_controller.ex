defmodule CrysaWeb.ProfileController do
  @moduledoc """
  Handles profile avatar uploads via `Crysa.Storage`.

  Uploads are validated strictly (allowlisted image types, max 2 MiB),
  stored with an unguessable key and persisted as a public URL on the
  user's profile.
  """

  use CrysaWeb, :controller

  alias Crysa.Accounts
  alias Crysa.Storage

  plug :require_authenticated_user

  defp require_authenticated_user(conn, _opts),
    do: CrysaWeb.UserAuth.require_authenticated_user(conn, [])

  @spec update_avatar(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def update_avatar(conn, %{"avatar" => %Plug.Upload{} = upload} = params) do
    return_to = redirect_target(params)

    case Storage.store_avatar(upload, conn.assigns.current_user) do
      {:ok, %{key: avatar_key}} ->
        case Accounts.update_profile(conn.assigns.current_user, %{avatar_key: avatar_key}) do
          {:ok, _profile} ->
            conn
            |> put_flash(:info, "Avatar updated.")
            |> redirect(to: return_to)

          {:error, _changeset} ->
            conn
            |> put_flash(:error, "Could not update avatar.")
            |> redirect(to: return_to)
        end

      {:error, message} when is_binary(message) ->
        conn
        |> put_flash(:error, message)
        |> redirect(to: return_to)

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Could not store the uploaded file.")
        |> redirect(to: return_to)
    end
  end

  def update_avatar(conn, params) when is_map(params) do
    conn
    |> put_flash(:error, "No file was uploaded.")
    |> redirect(to: redirect_target(params))
  end

  # Allowlist redirect targets to avoid open-redirect via user input.
  @spec redirect_target(map()) :: String.t()
  defp redirect_target(%{"return_to" => "/users/settings"}), do: "/users/settings"
  defp redirect_target(%{"return_to" => "/users/profile"}), do: "/users/profile"
  defp redirect_target(_params), do: "/users/profile"
end
