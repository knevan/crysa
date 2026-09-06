defmodule Crysa.Library.ViewBroadcaster do
  @moduledoc """
  Coalesced broadcaster for series view count updates.

  Chapter reads can burst (many readers on a popular series). Broadcasting
  every `record_view/2` would spam `series:<id>` subscribers. This server
  coalesces bursts per `series_id` with a 5 second window — only the latest
  authoritative `view_count` is broadcast.

  Callers invoke `notify/1` after the view transaction commits; the server
  fetches the authoritative counter and broadcasts
  `{:view_count_updated, view_count, series_id}`.
  """

  use GenServer

  require Logger

  @default_debounce_ms 5_000

  # Client

  @doc """
  Schedules a coalesced view count broadcast for the series.
  """
  @spec notify(integer()) :: :ok
  def notify(series_id) when is_integer(series_id) do
    # Never let realtime fanout crash the view transaction caller.
    try do
      case Process.whereis(__MODULE__) do
        nil -> :ok
        _pid -> GenServer.cast(__MODULE__, {:notify, series_id})
      end
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
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
  def handle_cast({:notify, series_id}, %{timers: timers} = state) do
    # Coalesce bursts: keep the first timer in the window, ignore repeats.
    # This bounds broadcasts to at most one per series per window.
    if Map.has_key?(timers, series_id) do
      {:noreply, state}
    else
      ref = Process.send_after(self(), {:broadcast, series_id}, debounce_ms())
      {:noreply, %{state | timers: Map.put(timers, series_id, ref)}}
    end
  end

  @impl true
  def handle_info({:broadcast, series_id}, %{timers: timers} = state) do
    timers = Map.delete(timers, series_id)

    try do
      case Crysa.Repo.get(Crysa.Catalog.Series, series_id) do
        nil ->
          :ok

        series ->
          Phoenix.PubSub.broadcast(
            Crysa.PubSub,
            "series:#{series_id}",
            {:view_count_updated, series.view_count, series_id}
          )
      end
    rescue
      e ->
        Logger.warning("ViewBroadcaster failed for series #{series_id}: #{inspect(e)}")
    end

    {:noreply, %{state | timers: timers}}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  defp debounce_ms do
    :crysa
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:debounce_ms, @default_debounce_ms)
  end
end
