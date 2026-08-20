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
  def update_avatar(conn, %{"avatar" => %Plug.Upload{} = upload}) do
    case Storage.store_avatar(upload, conn.assigns.current_user) do
      {:ok, %{url: avatar_url}} ->
        case Accounts.update_profile(conn.assigns.current_user, %{avatar_url: avatar_url}) do
          {:ok, _profile} ->
            conn
            |> put_flash(:info, "Avatar updated.")
            |> redirect(to: ~p"/users/profile")

          {:error, _changeset} ->
            conn
            |> put_flash(:error, "Could not update avatar.")
            |> redirect(to: ~p"/users/profile")
        end

      {:error, message} when is_binary(message) ->
        conn
        |> put_flash(:error, message)
        |> redirect(to: ~p"/users/profile")

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Could not store the uploaded file.")
        |> redirect(to: ~p"/users/profile")
    end
  end

  def update_avatar(conn, _params) do
    conn
    |> put_flash(:error, "No file was uploaded.")
    |> redirect(to: ~p"/users/profile")
  end
end
