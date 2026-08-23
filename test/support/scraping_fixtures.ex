defmodule Crysa.ScrapingFixtures do
  @moduledoc """
  Test fixtures for the Scraping context.
  """

  alias Crysa.Scraping

  @doc "A minimal valid scraping config document."
  @spec valid_config_attrs(map()) :: map()
  def valid_config_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        "selectors" => %{
          "chapter_link" => "div.chapter-list a",
          "image_on_chapter_page" => "#reader img"
        },
        "chapter_order" => "desc",
        "pagination" => %{"type" => "none"},
        "rate_limit" => %{
          "request_delay_ms" => %{"min" => 1_000, "max" => 3_000},
          "image_delay_ms" => %{"min" => 500, "max" => 1_500},
          "max_concurrent_requests" => 2
        }
      },
      overrides
    )
  end

  @spec unique_host() :: String.t()
  def unique_host do
    "site#{System.unique_integer([:positive])}.example.test"
  end

  @spec site_fixture(map()) :: Crysa.Scraping.Site.t()
  def site_fixture(attrs \\ %{}) do
    defaults = %{
      host: unique_host(),
      name: "Test Site"
    }

    {:ok, site} = Scraping.create_site(Map.merge(defaults, attrs))
    site
  end

  @spec draft_version_fixture(Crysa.Scraping.Site.t(), map()) :: Crysa.Scraping.SiteVersion.t()
  def draft_version_fixture(site, config_attrs \\ %{}) do
    {:ok, version} =
      Scraping.create_draft_version(site, valid_config_attrs(config_attrs))

    version
  end

  @doc "Site with a published config version."
  @spec published_site_fixture(map(), map()) :: %{
          site: Crysa.Scraping.Site.t(),
          version: Crysa.Scraping.SiteVersion.t()
        }
  def published_site_fixture(site_attrs \\ %{}, config_overrides \\ %{}) do
    site = site_fixture(site_attrs)
    version = draft_version_fixture(site, config_overrides)
    {:ok, %{site: site, version: version}} = Scraping.publish_version(site, version.id)
    %{site: site, version: version}
  end
end
