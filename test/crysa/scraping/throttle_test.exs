defmodule Crysa.Scraping.ThrottleTest do
  @moduledoc false

  # The throttle is a shared singleton GenServer; tests exercise real timing
  # behaviour and must not run concurrently with other stateful tests.
  use ExUnit.Case, async: false

  alias Crysa.Scraping.Throttle

  @host "throttle-test.example.test"

  test "grants immediately when under the concurrency cap" do
    settings = %Crysa.Scraping.Config.RateLimit{
      request_delay_ms: %{min: 10, max: 10},
      max_concurrent_requests: 2
    }

    start = System.monotonic_time(:millisecond)
    :ok = Throttle.acquire(@host, settings, :page)
    waited = System.monotonic_time(:millisecond) - start

    assert waited < 50
    Throttle.release(@host)
  end

  test "spaces consecutive starts by the configured delay" do
    settings = %Crysa.Scraping.Config.RateLimit{
      request_delay_ms: %{min: 150, max: 150},
      max_concurrent_requests: 1
    }

    :ok = Throttle.acquire(@host, settings, :page)
    Throttle.release(@host)

    start = System.monotonic_time(:millisecond)
    :ok = Throttle.acquire(@host, settings, :page)
    waited = System.monotonic_time(:millisecond) - start

    assert waited >= 100
    Throttle.release(@host)
  end

  test "blocks when the concurrency cap is reached and grants on release" do
    settings = %Crysa.Scraping.Config.RateLimit{
      request_delay_ms: %{min: 10, max: 10},
      max_concurrent_requests: 1
    }

    parent = self()

    :ok = Throttle.acquire(@host, settings, :page)

    task =
      Task.async(fn ->
        send(parent, :acquiring)
        Throttle.acquire(@host, settings, :page)
        send(parent, :acquired)
        Throttle.release(@host)
      end)

    assert_receive :acquiring
    refute_receive :acquired, 50

    Throttle.release(@host)
    assert_receive :acquired, 500
    Task.await(task)
  end

  test "reclaims slots when a caller crashes while holding them" do
    settings = %Crysa.Scraping.Config.RateLimit{
      request_delay_ms: %{min: 10, max: 10},
      max_concurrent_requests: 1
    }

    holder =
      spawn(fn ->
        Throttle.acquire(@host, settings, :page)
        Process.sleep(:infinity)
      end)

    # Wait until the holder actually owns the slot.
    wait_for_active(1)

    Process.exit(holder, :kill)
    wait_for_active(0)

    # The reclaimed slot must be grantable without a long delay.
    :ok = Throttle.acquire(@host, settings, :page)
    Throttle.release(@host)
  end

  test "image kind uses the image delay range" do
    settings = %Crysa.Scraping.Config.RateLimit{
      request_delay_ms: %{min: 5_000, max: 5_000},
      image_delay_ms: %{min: 20, max: 20},
      max_concurrent_requests: 1
    }

    :ok = Throttle.acquire(@host, settings, :image)
    Throttle.release(@host)

    start = System.monotonic_time(:millisecond)
    :ok = Throttle.acquire(@host, settings, :image)
    waited = System.monotonic_time(:millisecond) - start

    assert waited < 1_000
    Throttle.release(@host)
  end

  test "killed waiter does not exceed the concurrency cap" do
    settings = %Crysa.Scraping.Config.RateLimit{
      request_delay_ms: %{min: 10, max: 10},
      max_concurrent_requests: 1
    }

    parent = self()

    # Holder occupies the only slot.
    holder =
      spawn(fn ->
        Throttle.acquire(@host, settings, :page)
        send(parent, :holder_acquired)
        Process.sleep(:infinity)
      end)

    assert_receive :holder_acquired, 500

    # Two waiters queue behind the holder.
    w1 =
      spawn(fn ->
        Throttle.acquire(@host, settings, :page)
        send(parent, :w1_granted)
        Process.sleep(:infinity)
      end)

    _w2 =
      spawn(fn ->
        Throttle.acquire(@host, settings, :page)
        send(parent, :w2_granted)
        Process.sleep(:infinity)
      end)

    assert :ok = wait_for_queue(2)

    # Kill the FIRST waiter: no slot is freed, so W2 must stay queued and
    # `active` must remain at the cap (regression for P7-3).
    Process.exit(w1, :kill)
    Process.sleep(100)

    entry = Map.get(Throttle.snapshot(), @host)
    assert entry.active <= settings.max_concurrent_requests
    refute_receive :w2_granted, 200

    # Releasing the holder grants exactly one waiter.
    Throttle.release(@host)
    assert_receive :w2_granted, 500

    entry = Map.get(Throttle.snapshot(), @host)
    assert entry.active <= settings.max_concurrent_requests

    Process.exit(holder, :kill)
    Throttle.release(@host)
  end

  defp wait_for_queue(expected), do: wait_for_queue(expected, 50)

  defp wait_for_queue(_expected, 0), do: flunk("waiters did not queue in time")

  defp wait_for_queue(expected, remaining) do
    case Map.get(Throttle.snapshot(), @host) do
      %{waiters: q} ->
        if :queue.len(q) >= expected do
          :ok
        else
          Process.sleep(20)
          wait_for_queue(expected, remaining - 1)
        end

      _ ->
        Process.sleep(20)
        wait_for_queue(expected, remaining - 1)
    end
  end

  defp wait_for_active(expected) do
    wait_for_active(expected, 50)
  end

  defp wait_for_active(_expected, 0), do: flunk("throttle state did not converge")

  defp wait_for_active(expected, remaining) do
    case Map.get(Throttle.snapshot(), @host) do
      %{active: ^expected} ->
        :ok

      _ ->
        Process.sleep(20)
        wait_for_active(expected, remaining - 1)
    end
  end
end
