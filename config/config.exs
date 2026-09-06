import Config

config :live_vue, ssr: true, shared_props: []

config :bun,
  version: "1.3.14",
  assets: [args: [], cd: Path.expand("../assets", __DIR__)],
  update: [args: ~w(install), cd: Path.expand("../assets", __DIR__)],
  vite: [
    args: ~w(x vite),
    cd: Path.expand("../assets", __DIR__),
    env: %{"MIX_BUILD_PATH" => Mix.Project.build_path()}
  ]

config :crysa,
  ecto_repos: [Crysa.Repo],
  generators: [timestamp_type: :utc_datetime_usec]

# Configure the endpoint
config :crysa, CrysaWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: CrysaWeb.ErrorHTML, json: CrysaWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Crysa.PubSub,
  live_view: [signing_salt: "CUovuoEm"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure the mailer
config :crysa, Crysa.Mailer,
  adapter: Swoosh.Adapters.Local,
  from: {"CrysA", "noreply@crysa.example"}

# Configure esbuild (the version is required)
# config :esbuild,
#   version: "0.25.4",
#   crysa: [
#     args:
#       ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
#     cd: Path.expand("../assets", __DIR__),
#     env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
#   ]

# Configure tailwind (the version is required)
# config :tailwind,
#   version: "4.3.0",
#   crysa: [
#     args: ~w(
#       --input=assets/css/app.css
#       --output=priv/static/assets/css/app.css
#     ),
#     cd: Path.expand("..", __DIR__),
#     env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
#   ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [
    :request_id,
    :key,
    :status,
    :count,
    :host,
    :reason,
    :error,
    :errors,
    :adapter,
    :url,
    :body,
    :sample,
    :attempt,
    :series_id,
    :chapter_id,
    :objects,
    :operation,
    :action,
    :target_type,
    :target_id,
    :actor_id,
    :actor_role,
    :filename
  ]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Storage configuration
# Local adapter is used for dev/test; production overrides via config/runtime.exs
config :crysa, Crysa.Storage,
  adapter: Crysa.Storage.Local,
  storage_root: Path.expand("../priv/static/uploads", __DIR__),
  url_prefix: "/uploads",
  cdn_base_url: nil,
  trusted_cdn_urls: []

# Oban: durable background jobs (scraping checks, chapter downloads,
# repairs, deletions, cleanups). Queue concurrency is deliberately
# conservative; size from DB pool, target-host capacity and CPU budget.
config :crysa, Oban,
  repo: Crysa.Repo,
  queues: [series_checks: 4, chapter_downloads: 2, deletions: 1, maintenance: 1],
  plugins: [
    {Oban.Plugins.Cron,
     crontab: [
       {"* * * * *", Crysa.Processing.Jobs.SeriesCheckScheduler},
       {"17 */6 * * *", Crysa.Processing.Jobs.PasswordResetTokenCleanup},
       {"43 4 * * *", Crysa.Processing.Jobs.ViewLogCleanup}
     ]},
    {Oban.Plugins.Pruner, max_age: 7 * 24 * 60 * 60}
  ]

# Image encoding adapter (libvips via Vix, precompiled NIF + bundled libvips).
config :crysa, Crysa.Images, encoder: Crysa.Images.Encoder.Vix

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
