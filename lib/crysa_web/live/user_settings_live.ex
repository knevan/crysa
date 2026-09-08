defmodule CrysaWeb.UserSettingsLive do
  @moduledoc """
  Unified profile settings page backed by the `UserSettings` LiveVue island.

  Thin orchestration over `Crysa.Accounts` and `Crysa.Storage`; all business
  rules live in the contexts. Layout follows `ui-sketch/user-settings.pen`.

  Props sent to the island are explicit safe projections (scalars and
  translated error strings). Raw Ecto forms are never passed as props: a
  `User` changeset would leak `password_hash` through LiveVue's form
  encoder, and password values must only flow client → server.
  """

  use CrysaWeb, :live_view

  alias Crysa.Accounts
  alias Crysa.Storage
  alias CrysaWeb.CoreComponents

  on_mount {CrysaWeb.UserAuth, :mount_current_user}
  on_mount {CrysaWeb.UserAuth, :require_authenticated}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="sr-only" aria-hidden="true">Change Profile Settings</div>
    <.vue
      v-component="UserSettings"
      v-ssr={false}
      username={@current_user.username}
      avatarUrl={@avatar_url}
      avatarUpload={@uploads.avatar}
      avatarError={@avatar_error}
      account={@account}
      password={@password}
    />
    """
  end

  @impl true
  def mount(_params, session, socket) do
    user = socket.assigns.current_user
    profile = Accounts.get_or_create_profile(user)

    socket =
      allow_upload(socket, :avatar,
        accept: ~w(.jpg .jpeg .png .webp .gif),
        max_entries: 1,
        max_file_size: 2_000_000,
        auto_upload: true
      )

    {:ok,
     assign(socket,
       avatar_url: profile.avatar_url,
       avatar_error: nil,
       account: account_state(user.email, profile.display_name),
       password: password_state(),
       session_token: session["user_token"]
     )}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("validate_account", params, socket) do
    user = socket.assigns.current_user
    {email_attrs, profile_attrs} = split_account_params(params)

    email_changeset =
      user
      |> Accounts.change_user_email(email_attrs)
      |> Map.put(:action, :validate)

    profile_changeset =
      user
      |> Accounts.change_profile(profile_attrs)
      |> Map.put(:action, :validate)

    {:noreply,
     assign(socket,
       account:
         account_state(
           input_value(email_attrs, "email", user.email),
           input_value(profile_attrs, "display_name", current_display_name(socket)),
           field_errors(email_changeset, :email),
           field_errors(profile_changeset, :display_name)
         )
     )}
  end

  @impl true
  def handle_event("update_account", params, socket) do
    {email_attrs, profile_attrs} = split_account_params(params)
    {:noreply, apply_account_update(socket, email_attrs, profile_attrs)}
  end

  @impl true
  def handle_event("validate_password", %{"user" => params}, socket) do
    changeset =
      socket.assigns.current_user
      |> Accounts.change_user_password(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, password: password_state(changeset))}
  end

  @impl true
  def handle_event("update_password", %{"user" => params}, socket) do
    user = socket.assigns.current_user

    case Accounts.update_user_password(user, params, keep_session: socket.assigns.session_token) do
      {:ok, _user} ->
        {:noreply,
         socket
         |> assign(password: password_state())
         |> put_flash(:info, "Password updated successfully")}

      {:error, changeset} ->
        {:noreply, assign(socket, password: password_state(changeset))}
    end
  end

  @impl true
  def handle_event("validate_avatar", _params, socket) do
    {:noreply, assign(socket, :avatar_error, upload_error_message(socket))}
  end

  @impl true
  def handle_event("save_avatar", _params, socket) do
    {:noreply, apply_avatar_save(socket)}
  end

  # Validate both account models before writing either, to avoid partial updates.
  @spec apply_account_update(Phoenix.LiveView.Socket.t(), map(), map()) ::
          Phoenix.LiveView.Socket.t()
  defp apply_account_update(socket, email_attrs, profile_attrs) do
    user = socket.assigns.current_user
    email_changeset = Accounts.change_user_email(user, email_attrs)
    profile_changeset = Accounts.change_profile(user, profile_attrs)

    if email_changeset.valid? and profile_changeset.valid? do
      persist_account_update(socket, user, email_attrs, profile_attrs)
    else
      assign(socket,
        account:
          account_state(
            input_value(email_attrs, "email", user.email),
            input_value(profile_attrs, "display_name", current_display_name(socket)),
            field_errors(%{email_changeset | action: :validate}, :email),
            field_errors(%{profile_changeset | action: :validate}, :display_name)
          )
      )
    end
  end

  @spec persist_account_update(
          Phoenix.LiveView.Socket.t(),
          Accounts.User.t(),
          map(),
          map()
        ) :: Phoenix.LiveView.Socket.t()
  defp persist_account_update(socket, user, email_attrs, profile_attrs) do
    with {:ok, updated_user} <- Accounts.update_user_email(user, email_attrs),
         {:ok, profile} <- Accounts.update_profile(updated_user, profile_attrs) do
      refreshed = Accounts.get_user!(updated_user.id)

      socket
      |> assign(
        current_user: refreshed,
        account: account_state(refreshed.email, profile.display_name)
      )
      |> put_flash(:info, "Account information updated.")
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        assign(socket,
          account:
            account_state(
              input_value(email_attrs, "email", user.email),
              input_value(profile_attrs, "display_name", current_display_name(socket)),
              email_errors_for(changeset, user, email_attrs),
              profile_errors_for(changeset, user, profile_attrs)
            )
        )
    end
  end

  @spec apply_avatar_save(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp apply_avatar_save(socket) do
    user = socket.assigns.current_user

    # NOTE: `consume_uploaded_entries/3` returns the UNWRAPPED `{:ok, value}`
    # payloads (bare values, never `{:ok, ...}` tuples), so the fun tags its
    # own outcomes (`:stored` / `:storage_error`) for `resolve_avatar_outcome/2`.
    consumed =
      consume_uploaded_entries(socket, :avatar, fn %{path: path}, entry ->
        upload = %Plug.Upload{
          path: path,
          filename: entry.client_name,
          content_type: entry.client_type
        }

        case Storage.store_avatar(upload, user) do
          {:ok, %{url: _} = stored} ->
            {:ok, {:stored, stored}}

          {:error, message} when is_binary(message) ->
            {:ok, {:storage_error, message}}

          {:error, _reason} ->
            {:ok, {:storage_error, "Could not store the uploaded file."}}
        end
      end)

    persist_avatar_save(socket, user, consumed)
  end

  @spec persist_avatar_save(Phoenix.LiveView.Socket.t(), Accounts.User.t(), list()) ::
          Phoenix.LiveView.Socket.t()
  defp persist_avatar_save(socket, user, consumed) do
    case resolve_avatar_outcome(consumed, socket.assigns.uploads.avatar.errors) do
      {:saved, avatar_url} ->
        persist_avatar_url(socket, user, avatar_url)

      {:failed, message} ->
        socket
        |> assign(avatar_error: message)
        |> put_flash(:error, message)

      {:missing, message} ->
        assign(socket, :avatar_error, message)
    end
  end

  @doc """
  Resolves a `save_avatar` outcome from consumed entry results and upload errors.

  Pure decision function, extracted for direct testing. `consumed` holds the
  unwrapped `{:ok, value}` payloads returned by `consume_uploaded_entries/3`
  (bare values — matching on `{:ok, ...}` / `{:postpone, ...}` tuples here
  crashed the first implementation with a `CaseClauseError` AFTER the file
  had already been stored, leaving R2 with an orphan and the DB untouched).
  """
  @spec resolve_avatar_outcome(list(), list()) ::
          {:saved, String.t()} | {:failed, String.t()} | {:missing, String.t()}
  def resolve_avatar_outcome(consumed, upload_errors) do
    case {consumed, upload_errors} do
      {[{:stored, %{url: url}}], _} -> {:saved, url}
      {[{:storage_error, message}], _} -> {:failed, message}
      {[], []} -> {:missing, "No file was uploaded."}
      {[], [{_ref, reason} | _]} -> {:failed, upload_reason_message(reason)}
    end
  end

  @spec persist_avatar_url(Phoenix.LiveView.Socket.t(), Accounts.User.t(), String.t()) ::
          Phoenix.LiveView.Socket.t()
  defp persist_avatar_url(socket, user, avatar_url) do
    case Accounts.update_profile(user, %{avatar_url: avatar_url}) do
      {:ok, _profile} ->
        socket
        |> assign(avatar_url: avatar_url, avatar_error: nil)
        |> put_flash(:info, "Avatar updated.")

      {:error, _changeset} ->
        socket
        |> assign(avatar_error: "Could not update avatar.")
        |> put_flash(:error, "Could not update avatar.")
    end
  end

  # Account payload carries two namespaces: `user[email]` and
  # `user_profile[display_name]`. Slice to an allowlist so extra keys
  # (e.g. avatar_url, role_id) can never be mass-assigned here.
  @spec split_account_params(map()) :: {map(), map()}
  defp split_account_params(params) when is_map(params) do
    email_attrs =
      params
      |> Map.get("user", %{})
      |> Map.take(["email"])

    profile_attrs =
      params
      |> Map.get("user_profile", %{})
      |> Map.take(["display_name"])

    {email_attrs, profile_attrs}
  end

  # Safe projection for the island: scalars plus translated error strings.
  @spec account_state(String.t() | nil, String.t() | nil, [String.t()], [String.t()]) :: map()
  defp account_state(email, display_name, email_errors \\ [], display_name_errors \\ []) do
    %{
      email: email || "",
      displayName: display_name || "",
      emailErrors: email_errors,
      displayNameErrors: display_name_errors
    }
  end

  @spec password_state(Ecto.Changeset.t() | nil) :: map()
  defp password_state(changeset \\ nil) do
    %{
      errors: %{
        currentPassword: password_errors(changeset, :current_password),
        password: password_errors(changeset, :password),
        passwordConfirmation: password_errors(changeset, :password_confirmation)
      }
    }
  end

  @spec password_errors(Ecto.Changeset.t() | nil, atom()) :: [String.t()]
  defp password_errors(nil, _field), do: []
  defp password_errors(changeset, field), do: field_errors(changeset, field)

  @spec field_errors(Ecto.Changeset.t(), atom()) :: [String.t()]
  defp field_errors(changeset, field) do
    CoreComponents.translate_errors(changeset.errors, field)
  end

  # Echo the user's input back so typing is never clobbered by props.
  @spec input_value(map(), String.t(), String.t() | nil) :: String.t()
  defp input_value(attrs, key, fallback) do
    case Map.get(attrs, key) do
      value when is_binary(value) -> value
      _ -> fallback || ""
    end
  end

  @spec current_display_name(Phoenix.LiveView.Socket.t()) :: String.t() | nil
  defp current_display_name(socket) do
    socket.assigns.account.displayName
  end

  # The failing changeset belongs to either the email or the profile
  # update; surface its errors on the matching side.
  @spec email_errors_for(Ecto.Changeset.t(), Accounts.User.t(), map()) :: [String.t()]
  defp email_errors_for(changeset, user, email_attrs) do
    if changeset.data.__struct__ == Accounts.User do
      field_errors(changeset, :email)
    else
      user |> Accounts.change_user_email(email_attrs) |> field_errors(:email)
    end
  end

  @spec profile_errors_for(Ecto.Changeset.t(), Accounts.User.t(), map()) :: [String.t()]
  defp profile_errors_for(changeset, user, profile_attrs) do
    if changeset.data.__struct__ == Accounts.User do
      user |> Accounts.change_profile(profile_attrs) |> field_errors(:display_name)
    else
      field_errors(changeset, :display_name)
    end
  end

  @spec upload_error_message(Phoenix.LiveView.Socket.t()) :: String.t() | nil
  defp upload_error_message(socket) do
    case socket.assigns.uploads.avatar.errors do
      [] -> nil
      [{_ref, reason} | _] -> upload_reason_message(reason)
    end
  end

  @spec upload_reason_message(atom() | term()) :: String.t()
  defp upload_reason_message(:too_large), do: "The avatar must be 2 MB or smaller."

  defp upload_reason_message(:not_accepted),
    do: "Only JPEG, PNG, WebP, and GIF images are allowed."

  defp upload_reason_message(:too_many_files), do: "Please choose a single image file."
  defp upload_reason_message(_reason), do: "Could not store the uploaded file."
end
