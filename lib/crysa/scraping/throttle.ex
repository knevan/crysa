defmodule Crysa.Scraping.Throttle do
  @moduledoc """
  Centralized per-host outbound rate gate shared across Oban jobs.

  Enforcement point for the `rate_limit` namespace of scraping configs
  (`Crysa.Scraping.Config.RateLimit`): request delay ranges with random
  jitter and a per-host concurrency cap. All outbound scraping traffic goes
  through `acquire/2` before an HTTP attempt and `release/1` afterwards —
  never scattered `Process.sleep/1` calls at individual call sites.

  ## Design

  A single GenServer owns all per-host state. `acquire/2` computes the
  earliest allowed start time (`last_start + jitter(min..max)`), reserves a
  concurrency slot and schedules the reply via `Process.send_after/3`, so
  waiting callers block their own job process without blocking other hosts
  or the server. When all slots are busy, callers enter a FIFO wait queue
  and are granted on `release/1`.

  Callers are monitored: if a job crashes while holding a slot (or while
  queued), the slot is reclaimed automatically on `:DOWN` — permits cannot
  leak.

  Safe defaults apply when no config is supplied (delay 1–3 s, concurrency
  2), mirroring Castra's `random_sleep_time(2, 5)` behaviour with tighter,
  config-driven bounds.

  Emits `[:crysa, :scraping, :throttle, :grant]` telemetry with a `wait_ms`
  measurement.
  """

  use GenServer

  @defaults %{min_ms: 1_000, max_ms: 3_000, max_concurrent: 2}

  # `GenServer.call/3` defaults to 5 s, but legitimate waits are bounded only
  # by the configured delay ceiling (60 s) times the number of queued callers
  # ahead of us — easily beyond 5 s under load. A raw call-timeout exit would
  # fail the fetch spuriously; this generous bound keeps normal operation
  # blocking while still surfacing a pathological wedge eventually (the
  # monitor-based DOWN cleanup means a timed-out acquire leaks nothing).
  @acquire_timeout :timer.minutes(5)

  @type rate_limit :: Crysa.Scraping.Config.RateLimit.t() | nil

  # -- Client API --------------------------------------------------------------

  @doc "Starts the throttle server (part of the supervision tree)."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @doc """
  Blocks the caller until a request to `host` may start.

  `kind` selects the configured delay range: `:page` uses
  `rate_limit.request_delay_ms`, `:image` uses `rate_limit.image_delay_ms`.
  Both share the same per-host concurrency slots and start-spacing chain.

  Returns `:ok` once the caller owns a concurrency slot; the caller must
  invoke `release/1` after the request completes (success or failure).
  """
  @spec acquire(String.t(), rate_limit(), :page | :image) :: :ok
  def acquire(host, rate_limit \\ nil, kind \\ :page) when is_binary(host) do
    GenServer.call(
      __MODULE__,
      {:acquire, normalize_host(host), settings(rate_limit, kind)},
      @acquire_timeout
    )
  end

  @doc "Releases the slot held by the caller for `host`."
  @spec release(String.t()) :: :ok
  def release(host) when is_binary(host) do
    GenServer.cast(__MODULE__, {:release, self(), normalize_host(host)})
  end

  @doc "Current per-host snapshot (introspection/testing)."
  @spec snapshot() :: map()
  def snapshot do
    GenServer.call(__MODULE__, :snapshot)
  end

  # -- Server -------------------------------------------------------------------

  @impl true
  def init(:ok) do
    {:ok, %{hosts: %{}, monitors: %{}}}
  end

  @impl true
  def handle_call({:acquire, host, settings}, from, state) do
    now = now_ms()
    entry = Map.get(state.hosts, host, new_entry())
    ref = Process.monitor(elem(from, 0))

    if entry.active < settings.max_concurrent do
      grant(host, from, settings, entry, now, ref, state)
    else
      state =
        put_in(state.hosts[host], %{
          entry
          | waiters: :queue.in({from, settings, ref}, entry.waiters)
        })
        |> put_in([:monitors, ref], {host, elem(from, 0)})

      {:noreply, state}
    end
  end

  def handle_call(:snapshot, _from, state) do
    {:reply, state.hosts, state}
  end

  @impl true
  def handle_cast({:release, pid, host}, state) do
    {:noreply, handle_release(host, pid, state)}
  end

  @impl true
  def handle_info({:grant, from}, state) do
    GenServer.reply(from, :ok)
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _} ->
        {:noreply, state}

      {{host, ^pid}, monitors} ->
        {:noreply, host |> reclaim(pid, %{state | monitors: monitors})}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  # -- granting ------------------------------------------------------------------

  defp grant(host, from, settings, entry, now, ref, state) do
    wait = start_delay(entry.last_start_at, jitter(settings), now)

    entry = %{
      entry
      | active: entry.active + 1,
        last_start_at: now + wait
    }

    state =
      put_in(state.hosts[host], entry)
      |> put_in([:monitors, ref], {host, elem(from, 0)})

    emit_grant(host, wait)

    if wait <= 0 do
      GenServer.reply(from, :ok)
      {:noreply, state}
    else
      Process.send_after(self(), {:grant, from}, wait)
      {:noreply, state}
    end
  end

  defp handle_release(host, _pid, state) do
    case Map.get(state.hosts, host) do
      nil ->
        state

      entry ->
        entry = %{entry | active: max(entry.active - 1, 0)}
        state = put_in(state.hosts[host], entry)
        maybe_grant_waiter(host, entry, now_ms(), state)
    end
  end

  defp maybe_grant_waiter(host, entry, now, state) do
    case :queue.out(entry.waiters) do
      {:empty, _queue} ->
        state

      {{:value, {from, settings, _ref}}, rest} ->
        entry = %{entry | waiters: rest, active: entry.active + 1}
        wait = start_delay(entry.last_start_at, jitter(settings), now)
        entry = %{entry | last_start_at: now + wait}
        emit_grant(host, wait)

        state =
          put_in(state.hosts[host], entry)

        if wait <= 0 do
          GenServer.reply(from, :ok)
          state
        else
          Process.send_after(self(), {:grant, from}, wait)
          state
        end
    end
  end

  # Crash recovery: the dead pid either held a slot or sat in the wait queue.
  defp reclaim(host, pid, state) do
    case Map.get(state.hosts, host) do
      nil ->
        state

      entry ->
        waiting? = fn {from, _settings, _ref} -> elem(from, 0) == pid end

        if Enum.any?(:queue.to_list(entry.waiters), waiting?) do
          # A queued caller held no slot: remove it WITHOUT granting a waiter,
          # otherwise `active` would exceed the configured concurrency cap.
          waiters =
            entry.waiters
            |> :queue.to_list()
            |> Enum.reject(waiting?)
            |> :queue.from_list()

          put_in(state.hosts[host], %{entry | waiters: waiters})
        else
          entry = %{entry | active: max(entry.active - 1, 0)}
          state = put_in(state.hosts[host], entry)
          maybe_grant_waiter(host, entry, now_ms(), state)
        end
    end
  end

  # -- helpers ---------------------------------------------------------------------

  defp new_entry do
    # last_start_at is nil until the first grant; the BEAM monotonic clock
    # has an arbitrary (possibly negative) origin, so 0 is not "now".
    %{active: 0, last_start_at: nil, waiters: :queue.new()}
  end

  defp start_delay(nil, _jitter_ms, _now), do: 0
  defp start_delay(last_start_at, jitter_ms, now), do: max(last_start_at + jitter_ms - now, 0)

  defp settings(nil, _kind), do: @defaults

  defp settings(%Crysa.Scraping.Config.RateLimit{} = rl, kind) do
    range = if kind == :image, do: rl.image_delay_ms, else: rl.request_delay_ms

    %{
      min_ms: range && range.min,
      max_ms: range && range.max,
      max_concurrent: rl.max_concurrent_requests || @defaults.max_concurrent
    }
  end

  defp jitter(%{min_ms: nil, max_ms: nil}), do: jitter(@defaults)
  defp jitter(%{min_ms: nil}), do: jitter(%{@defaults | min_ms: @defaults.min_ms})
  defp jitter(%{max_ms: nil}), do: jitter(%{@defaults | max_ms: @defaults.max_ms})

  defp jitter(%{min_ms: min, max_ms: max}) when min > max, do: max
  defp jitter(%{min_ms: min, max_ms: max}) when min == max, do: min
  defp jitter(%{min_ms: min, max_ms: max}), do: Enum.random(min..max)

  defp normalize_host(host), do: String.downcase(String.trim(host))

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp emit_grant(host, wait_ms) do
    :telemetry.execute(
      [:crysa, :scraping, :throttle, :grant],
      %{wait_ms: wait_ms},
      %{host: host}
    )
  end
end
