defmodule Crysa.Library.RatingBroadcaster do
  @moduledoc """
  Debounced broadcaster for series rating updates.

  Rating taps can happen rapidly (tap-hold + slide). Broadcasting every tap
  would spam `series:<id>` subscribers. This GenServer coalesces bursts
  per series_id with a 500ms debounce — only the last rating in the window
  is broadcast as full distribution (accurate for progress bars).

  The caller (`Crysa.Library.rate_series/3` / `unrate_series/2`) should invoke
  `debounce_broadcast/1` after the transaction commits; the broadcaster will
  fetch the authoritative summary/distribution and `Phoenix.PubSub.broadcast`.
  """

  use GenServer

  require Logger

  @debounce_ms 500

  # Client

  @spec debounce_broadcast(integer()) :: :ok
  def debounce_broadcast(series_id) when is_integer(series_id) do
    GenServer.cast(__MODULE__, {:debounce, series_id})
  end

  # Server

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    {:ok, %{timers: %{}}}
  end

  @impl true
  def handle_cast({:debounce, series_id}, %{timers: timers} = state) do
    # Cancel previous timer for this series, if any
    timers =
      case Map.get(timers, series_id) do
        nil ->
          timers

        ref ->
          Process.cancel_timer(ref)
          Map.delete(timers, series_id)
      end

    ref = Process.send_after(self(), {:broadcast, series_id}, @debounce_ms)
    {:noreply, %{state | timers: Map.put(timers, series_id, ref)}}
  end

  @impl true
  def handle_info({:broadcast, series_id}, %{timers: timers} = state) do
    timers = Map.delete(timers, series_id)

    # Fetch authoritative aggregates outside lock
    try do
      series = Crysa.Repo.get(Crysa.Catalog.Series, series_id)

      if series do
        # Preload not needed; rating_distribution/1 queries series_ratings directly
        summary = Crysa.Library.rating_summary(series)
        dist = Crysa.Library.rating_distribution(series_id)

        Phoenix.PubSub.broadcast(
          Crysa.PubSub,
          "series:#{series_id}",
          {:rating_updated, summary, dist, series_id}
        )
      end
    rescue
      e ->
        Logger.warning("RatingBroadcaster failed for series #{series_id}: #{inspect(e)}")
    end

    {:noreply, %{state | timers: timers}}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}
end
