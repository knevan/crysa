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

  defp plug_require_authenticated_user(conn, _opts),
    do: CrysaWeb.UserAuth.require_authenticated_user(conn, [])

  defp plug_require_moderator(conn, _opts), do: CrysaWeb.UserAuth.require_moderator(conn, [])
  defp plug_require_admin(conn, _opts), do: CrysaWeb.UserAuth.require_admin(conn, [])

  scope "/", CrysaWeb do
    pipe_through [:browser, :auth]

    get "/", PageController, :home

    # Series
    get "/series", CatalogController, :index
    get "/series/:slug", CatalogController, :show
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

    # Websocket
    live_session :current_user, on_mount: [{CrysaWeb.UserAuth, :mount_current_user}] do
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

  scope "/moderator", CrysaWeb, as: :moderator do
    pipe_through [:browser, :auth, :moderator]

    get "/", ModeratorDashboardController, :index
  end

  scope "/admin", CrysaWeb, as: :admin do
    pipe_through [:browser, :auth, :admin]

    get "/", AdminDashboardController, :index
  end

  # Other scopes may use custom stacks.
  # scope "/api", CrysaWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:crysa, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through [:browser, :auth, :admin]

      live_dashboard "/dashboard", metrics: CrysaWeb.Telemetry
      live "/vue-demo", CrysaWeb.VueDemoLive
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
