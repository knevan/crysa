defmodule Crysa.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      CrysaWeb.Telemetry,
      Crysa.Repo,
      {DNSCluster, query: Application.get_env(:crysa, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Crysa.PubSub},
      # Debounced rating broadcast for realtime progress bars
      Crysa.Library.RatingBroadcaster,
      # Coalesced view count broadcast (5s window) for realtime stats
      Crysa.Library.ViewBroadcaster,
      # Per-host outbound rate gate shared by all scraping jobs.
      Crysa.Scraping.Throttle,
      # ETS owner for the published-config read-through cache.
      Crysa.Scraping.ConfigCache,
      # Durable background job processing.
      {Oban, Application.fetch_env!(:crysa, Oban)},
      CrysaWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Crysa.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    CrysaWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
