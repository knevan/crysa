defmodule Crysa.Scraping.ConfigCache do
  @moduledoc """
  ETS read-through cache for published scraping config snapshots.

  Plan requirement: *"Cache published configs in GenServer/ETS to avoid
  repeated DB reads in hot paths."* Workers resolve the snapshot at job
  start; without a cache every job start pays a DB round trip.

  Invalidation is event-driven: `Crysa.Scraping.publish_version/3` and
  `update_site/2` delete the affected host's entry, so the next resolution
  reloads from the database. Cached values are immutable snapshots — jobs
  that already captured one keep it for their whole run (snapshot
  semantics). A low-frequency periodic sync can be added later if cache
  drift across nodes ever becomes a concern.
  """

  use GenServer

  @table :crysa_scraping_config_cache

  # -- Client API --------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @doc """
  Read-through lookup. Returns the cached value, or runs `loader_fun` on a
  miss and caches its result (including negative results such as
  `{:error, :no_published_config}`) before returning it.
  """
  @spec get(String.t(), (-> value)) :: value when value: var
  def get(host, loader_fun) when is_binary(host) do
    case :ets.lookup(@table, host) do
      [{^host, value}] ->
        value

      [] ->
        value = loader_fun.()
        :ets.insert(@table, {host, value})
        value
    end
  end

  @doc "Drops the cached entry for `host`."
  @spec invalidate(String.t()) :: :ok
  def invalidate(host) when is_binary(host) do
    :ets.delete(@table, host)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Drops all cached entries."
  @spec invalidate_all() :: :ok
  def invalidate_all do
    :ets.delete_all_objects(@table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Test helper: current cache contents."
  @spec snapshot() :: map()
  def snapshot do
    Map.new(:ets.tab2list(@table))
  rescue
    ArgumentError -> %{}
  end

  # -- Server -------------------------------------------------------------------

  @impl true
  def init(:ok) do
    table =
      :ets.new(@table, [
        :set,
        :named_table,
        :public,
        read_concurrency: true
      ])

    {:ok, table}
  end
end
