defmodule Crysa.LibraryViewBroadcasterTest do
  @moduledoc """
  Tests for coalesced view count broadcasts.

  Views are counted on chapter reads; `ViewBroadcaster` fans out the
  authoritative counter at most once per series per window so open series
  pages update without refresh.
  """

  use Crysa.DataCase, async: false

  alias Crysa.CatalogFixtures
  alias Crysa.Library
  alias Crysa.Library.ViewBroadcaster

  setup do
    series = CatalogFixtures.series_fixture()
    %{series: series}
  end

  test "record_view notifies and broadcasts coalesced view count", %{series: series} do
    previous = Application.get_env(:crysa, ViewBroadcaster, [])
    Application.put_env(:crysa, ViewBroadcaster, debounce_ms: 50)
    on_exit(fn -> Application.put_env(:crysa, ViewBroadcaster, previous) end)

    Phoenix.PubSub.subscribe(Crysa.PubSub, "series:#{series.id}")

    assert {:ok, _} = Library.record_view(series)
    assert {:ok, _} = Library.record_view(series)

    assert_receive {:view_count_updated, 2, series_id}, 500
    assert series_id == series.id

    # Coalesced: bursts in one window produce a single broadcast.
    refute_received {:view_count_updated, _, _}
  end

  test "notify is safe when server is unavailable" do
    # Must never crash the caller; returns :ok even for unknown series.
    assert :ok = ViewBroadcaster.notify(-1)
  end
end
