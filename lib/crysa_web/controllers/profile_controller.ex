defmodule CrysaWeb.ProfileController do
  @moduledoc """
  Handles profile avatar uploads.
  """

  use CrysaWeb, :controller

  alias Crysa.Accounts

  plug :require_authenticated_user

  defp require_authenticated_user(conn, _opts),
    do: CrysaWeb.UserAuth.require_authenticated_user(conn, [])

  @max_avatar_bytes 2 * 1024 * 1024
  @allowed_content_types %{
    "image/jpeg" => ".jpg",
    "image/png" => ".png",
    "image/webp" => ".webp",
    "image/gif" => ".gif"
  }

  @spec update_avatar(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def update_avatar(conn, %{"avatar" => %Plug.Upload{} = upload}) do
    case store_avatar(upload) do
      {:ok, avatar_url} ->
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

      {:error, message} ->
        conn
        |> put_flash(:error, message)
        |> redirect(to: ~p"/users/profile")
    end
  end

  def update_avatar(conn, _params) do
    conn
    |> put_flash(:error, "No file was uploaded.")
    |> redirect(to: ~p"/users/profile")
  end

  defp store_avatar(%Plug.Upload{content_type: content_type, path: path}) do
    with {:ok, extension} <- validate_content_type(content_type),
         {:ok, size} <- file_size(path),
         :ok <- validate_size(size) do
      persist_avatar(path, extension)
    else
      {:error, message} when is_binary(message) -> {:error, message}
      {:error, _reason} -> {:error, "Could not read the uploaded file."}
    end
  end

  defp persist_avatar(path, extension) do
    key = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
    filename = key <> extension
    uploads_dir = Path.join([:code.priv_dir(:crysa), "static", "uploads", "avatars"])

    case File.mkdir_p(uploads_dir) do
      :ok -> copy_avatar(path, uploads_dir, filename)
      {:error, _reason} -> {:error, "Could not store the uploaded file."}
    end
  end

  defp copy_avatar(path, uploads_dir, filename) do
    case File.cp(path, Path.join(uploads_dir, filename)) do
      :ok -> {:ok, "/uploads/avatars/#{filename}"}
      {:error, _reason} -> {:error, "Could not store the uploaded file."}
    end
  end

  defp file_size(path) do
    case File.stat(path, time: :posix) do
      {:ok, stat} -> {:ok, stat.size}
      {:error, _reason} -> {:error, :stat_failed}
    end
  end

  defp validate_content_type(content_type) do
    case @allowed_content_types[content_type] do
      nil -> {:error, "Only JPEG, PNG, WebP, and GIF images are allowed."}
      extension -> {:ok, extension}
    end
  end

  defp validate_size(size) when size <= @max_avatar_bytes, do: :ok
  defp validate_size(_size), do: {:error, "The avatar must be 2 MB or smaller."}
end
