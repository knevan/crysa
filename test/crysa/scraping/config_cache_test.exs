defmodule Crysa.Scraping.ConfigCacheTest do
  @moduledoc false

  use Crysa.DataCase, async: true

  import Crysa.ScrapingFixtures

  alias Crysa.Scraping
  alias Crysa.Scraping.ConfigCache

  setup do
    # The ETS table is global; start each test from a clean slate.
    ConfigCache.invalidate_all()
    :ok
  end

  test "get/2 caches the loader result" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    loader = fn ->
      Agent.update(counter, &(&1 + 1))
      {:ok, :snapshot}
    end

    assert {:ok, :snapshot} = ConfigCache.get("host.example.test", loader)
    assert {:ok, :snapshot} = ConfigCache.get("host.example.test", loader)
    assert Agent.get(counter, & &1) == 1
  end

  test "negative results are cached too" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    loader = fn ->
      Agent.update(counter, &(&1 + 1))
      {:error, :no_published_config}
    end

    assert {:error, :no_published_config} = ConfigCache.get("missing.example.test", loader)
    assert {:error, :no_published_config} = ConfigCache.get("missing.example.test", loader)
    assert Agent.get(counter, & &1) == 1
  end

  test "invalidate/1 forces a reload" do
    host = "inv.example.test"

    assert {:ok, :v1} = ConfigCache.get(host, fn -> {:ok, :v1} end)
    ConfigCache.invalidate(host)
    assert {:ok, :v2} = ConfigCache.get(host, fn -> {:ok, :v2} end)
  end

  test "publish_version invalidates the site's cached snapshot" do
    %{site: site} = published_site_fixture()

    assert {:ok, %{config: config1}} = Scraping.published_config_for_host(site.host)
    assert Map.has_key?(ConfigCache.snapshot(), site.host)

    # Publish a modified draft; the cache must not serve the stale snapshot.
    {:ok, v2} =
      Scraping.create_draft_version(site, %{
        "selectors" => %{"chapter_link" => "a.new", "image_on_chapter_page" => "img.new"}
      })

    {:ok, _} = Scraping.publish_version(site, v2.id)

    assert {:ok, %{config: config2}} = Scraping.published_config_for_host(site.host)
    assert config2.selectors.chapter_link == "a.new"
    refute config2.selectors.chapter_link == config1.selectors.chapter_link
  end

  test "update_site invalidates so disabled sites are reflected immediately" do
    %{site: site} = published_site_fixture()

    assert {:ok, _} = Scraping.published_config_for_host(site.host)
    Scraping.update_site(site, %{enabled: false})

    assert {:error, :site_disabled} = Scraping.published_config_for_host(site.host)
  end
end
