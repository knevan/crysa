import Config
import Nvir

dotenv!(
  dev: ".env.dev",
  test: ".env.test"
)

database_url =
  case env!("DATABASE_URL", :string, "") do
    "" -> nil
    url -> String.trim(url)
  end

if env!("PHX_SERVER", :string, "") != "" do
  config :crysa, CrysaWeb.Endpoint, server: true
end

config :crysa, CrysaWeb.Endpoint, http: [port: env!("PORT", :integer!, 4000)]

if config_env() in [:dev, :test] and database_url do
  config :crysa, Crysa.Repo, url: database_url
end

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :crysa, CrysaWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Gettext translations
        ~r"priv/gettext/.*\.po$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/crysa_web/router\.ex$"E,
        ~r"lib/crysa_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  maybe_ipv6 = if env!("ECTO_IPV6", :boolean!, false), do: [:inet6], else: []

  config :crysa, Crysa.Repo,
    # ssl: true,
    url: database_url,
    pool_size: env!("POOL_SIZE", :integer!, 10),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    env!("SECRET_KEY_BASE", :string!, nil) ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = env!("PHX_HOST", :string!, nil) || "example.com"

  config :crysa, :dns_cluster_query, env!("DNS_CLUSTER_QUERY", :string!, nil)

  config :crysa, CrysaWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      ip: {0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :crysa, CrysaWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :crysa, CrysaWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :crysa, Crysa.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://swoosh.hexdocs.pm/Swoosh.html#module-installation for details.
end

# Storage configuration — S3-compatible, vendor-neutral
# For local dev/test without S3, Local adapter is used (priv/static/uploads).
if config_env() in [:dev, :test, :prod] do
  bucket_name = env!("BUCKET_NAME", :string, nil)
  account_id = env!("ACCOUNT_ID", :string, nil)
  endpoint_url = env!("ENDPOINT_URL", :string, nil)
  access_key_id = env!("ACCESS_KEY_ID", :string, nil)
  secret_access_key = env!("SECRET_ACCESS_KEY", :string, nil)
  region = env!("REGION", :string, "auto")
  domain_cdn_url = env!("DOMAIN_CDN_URL", :string, nil)

  # Basic vendor-neutral validation: endpoint must be https:// if present
  endpoint_url =
    cond do
      is_nil(endpoint_url) or endpoint_url == "" ->
        nil

      String.starts_with?(endpoint_url, "https://") ->
        endpoint_url

      true ->
        require Logger

        Logger.warning(
          "storage endpoint should be https://, got #{String.slice(endpoint_url, 0, 80)}"
        )

        endpoint_url
    end

  if bucket_name && access_key_id && secret_access_key && endpoint_url do
    config :crysa, Crysa.Storage,
      adapter: Crysa.Storage.S3,
      bucket: bucket_name,
      account_id: account_id,
      endpoint_url: endpoint_url,
      access_key_id: access_key_id,
      secret_access_key: secret_access_key,
      region: region,
      cdn_base_url: domain_cdn_url,
      trusted_cdn_urls:
        if(domain_cdn_url && domain_cdn_url != "",
          do: [String.trim_trailing(domain_cdn_url, "/")],
          else: []
        )
  else
    if domain_cdn_url && domain_cdn_url != "" do
      trimmed = String.trim_trailing(domain_cdn_url, "/")

      config :crysa, Crysa.Storage,
        adapter: Crysa.Storage.Local,
        storage_root: Path.expand("../priv/static/uploads", __DIR__),
        url_prefix: "/uploads",
        cdn_base_url: trimmed,
        trusted_cdn_urls: [trimmed]
    else
      # Prod without S3 and without CDN → must explicitly allow ephemeral Local
      if config_env() == :prod and System.get_env("STORAGE_ADAPTER") != "local" and
           is_nil(bucket_name) do
        raise """
        S3 storage not configured in prod: set BUCKET_NAME, ENDPOINT_URL (https://...), ACCESS_KEY_ID, SECRET_ACCESS_KEY and DOMAIN_CDN_URL,
        or set STORAGE_ADAPTER=local to allow ephemeral local storage (data will be lost on redeploy).
        """
      end
    end
  end
end
