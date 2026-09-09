defmodule CrysaWeb.Router do
  use CrysaWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {CrysaWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :auth do
    plug :plug_fetch_current_user
    plug :plug_fetch_notification_badge
  end

  pipeline :require_authenticated_user do
    plug :plug_require_authenticated_user
  end

  pipeline :moderator do
    plug :plug_require_moderator
  end

  pipeline :admin do
    plug :plug_require_admin
  end

  defp plug_fetch_current_user(conn, _opts), do: CrysaWeb.UserAuth.fetch_current_user(conn, [])

  # Snapshot badge for the header bell. One indexed count query, skipped
  # for guests. Live navigation does not re-render the root layout, so
  # the badge refreshes on full page loads; the panel itself is realtime.
  defp plug_fetch_notification_badge(conn, _opts) do
    count =
      case conn.assigns[:current_user] do
        %{id: id} -> Crysa.Notifications.unread_count(id)
        _ -> 0
      end

    assign(conn, :unread_notifications_count, count)
  end

  defp plug_require_authenticated_user(conn, _opts),
    do: CrysaWeb.UserAuth.require_authenticated_user(conn, [])

  defp plug_require_moderator(conn, _opts), do: CrysaWeb.UserAuth.require_moderator(conn, [])
  defp plug_require_admin(conn, _opts), do: CrysaWeb.UserAuth.require_admin(conn, [])

  scope "/", CrysaWeb do
    pipe_through [:browser, :auth]

    get "/", PageController, :home

    # Series (browse)
    get "/series", CatalogController, :index
    get "/series/:slug/:chapter_key", CatalogController, :reader
    get "/popular", CatalogController, :popular
    get "/updates", CatalogController, :updates
    get "/tags", CatalogController, :tags

    # Authentication
    scope "/auth" do
      post "/login", UserSessionController, :create
      delete "/logout", UserSessionController, :delete
      post "/register", UserRegistrationController, :create
      post "/reset-password", UserForgotPasswordController, :create
    end

    # User Profile & Settings
    scope "/users" do
      post "/reset-password/:token", UserResetPasswordController, :update
      post "/profile/avatar", ProfileController, :update_avatar
    end

    # Websocket - auth pages
    live_session :current_user, on_mount: [{CrysaWeb.UserAuth, :mount_current_user}] do
      live "/notifications", Live.NotificationsLive, :index
      live "/bookmarks", Live.BookmarkLive, :index

      scope "/auth" do
        live "/login", UserLoginLive, :new
        live "/register", UserRegistrationLive, :new
        live "/reset-password", UserForgotPasswordLive, :new
      end

      scope "/users" do
        live "/reset-password/:token", UserResetPasswordLive, :edit
        live "/settings", UserSettingsLive, :edit
        live "/profile", ProfileLive, :edit
      end
    end
  end

  # Series detail
  # Uses v-ssr for crawler-visible HTML. View tracking is best-effort.
  live_session :series_show, on_mount: [{CrysaWeb.UserAuth, :mount_current_user}] do
    scope "/", CrysaWeb do
      pipe_through [:browser, :auth]

      live "/series/:slug", Live.SeriesShowLive, :show
    end
  end

  scope "/moderator", CrysaWeb, as: :moderator do
    pipe_through [:browser, :auth, :moderator]

    get "/", ModeratorDashboardController, :index
  end

  # Admin dashboard LiveView.
  live_session :admin_dashboard,
    on_mount: [{CrysaWeb.UserAuth, :mount_current_user}] do
    scope "/admin", CrysaWeb do
      pipe_through [:browser, :auth]

      live "/", Live.AdminDashboardLive, :index
    end
  end

  scope "/admin", CrysaWeb, as: :admin do
    pipe_through [:browser, :auth, :admin]

    get "/legacy", AdminDashboardController, :index
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:crysa, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through [:browser, :auth, :admin]

      live_dashboard "/dashboard", metrics: CrysaWeb.Telemetry
      live "/vue-demo", CrysaWeb.VueDemoLive
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
