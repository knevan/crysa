defmodule CrysaWeb.ProfileLive do
  @moduledoc """
  User profile page.
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
          <p>Your profile</p>
          <:subtitle>@{@current_user.username}</:subtitle>
        </.header>
      </div>

      <div class="flex justify-center">
        <div class="avatar">
          <div class="w-28 rounded-full ring ring-primary ring-offset-2">
            <img src={@profile.avatar_url || ~p"/images/placeholder.png"} alt="avatar" />
          </div>
        </div>
      </div>

      <.simple_form for={@form} id="profile_form" phx-submit="update_profile">
        <.input field={@form[:display_name]} label="Display name" />
        <:actions>
          <.button class="w-full">Save profile</.button>
        </:actions>
      </.simple_form>

      <div class="card w-full bg-base-100 shadow-xl mx-auto">
        <div class="card-body">
          <h2 class="card-title text-sm">Change avatar</h2>
          <.form
            for={%{}}
            action={~p"/users/profile/avatar"}
            method="post"
            multipart
            class="flex flex-col gap-4"
          >
            <input
              type="file"
              name="avatar"
              accept="image/jpeg,image/png,image/webp,image/gif"
              class="file-input file-input-bordered w-full"
              required
            />
            <.button class="w-full" type="submit">Upload avatar</.button>
          </.form>
          <p class="text-xs opacity-70">
            Maximum 2 MB. JPEG, PNG, WebP, or GIF.
          </p>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    profile = Accounts.get_or_create_profile(user)

    {:ok,
     assign(socket,
       profile: profile,
       form: to_form(Accounts.change_profile(user))
     )}
  end

  @impl true
  def handle_event("update_profile", %{"user_profile" => params}, socket) do
    user = socket.assigns.current_user

    case Accounts.update_profile(user, params) do
      {:ok, profile} ->
        {:noreply,
         socket
         |> assign(profile: profile, form: to_form(Accounts.change_profile(user)))
         |> put_flash(:info, "Profile updated")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end
end
