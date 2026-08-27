defmodule Crysa.Scraping.SitesTest do
  @moduledoc false

  use Crysa.DataCase, async: true

  import Crysa.ScrapingFixtures

  alias Crysa.Scraping
  alias Crysa.Scraping.Config

  describe "create_site/1" do
    test "normalizes and validates host" do
      {:ok, site} = Scraping.create_site(%{host: "  Example.Test ", name: "Example"})
      assert site.host == "example.test"

      assert {:error, cs} = Scraping.create_site(%{host: "not a host", name: "Bad"})
      assert "is not a valid hostname" in errors_on(cs).host
    end

    test "enforces unique hosts case-insensitively (via normalization)" do
      site = site_fixture()
      assert {:error, cs} = Scraping.create_site(%{host: String.upcase(site.host), name: "Dup"})
      assert "has already been taken" in errors_on(cs).host
    end
  end

  describe "create_draft_version/3" do
    test "assigns sequential versions and stores validated config with checksum" do
      site = site_fixture()

      {:ok, v1} = Scraping.create_draft_version(site, valid_config_attrs())
      assert v1.version == 1
      assert v1.status == "draft"
      assert byte_size(v1.checksum) == 64

      {:ok, v2} = Scraping.create_draft_version(site, valid_config_attrs())
      assert v2.version == 2
    end

    test "rejects invalid config documents without touching published state" do
      site = site_fixture()

      _published =
        draft_version_fixture(site) |> then(fn v -> Scraping.publish_version(site, v.id) end)

      assert {:error, cs} =
               Scraping.create_draft_version(site, %{"selectors" => %{"chapter_link" => ""}})

      assert errors_on(cs).config |> List.first() =~ "is invalid"
    end
  end

  describe "publish_version/3" do
    test "publishes a draft and moves the site pointer" do
      site = site_fixture()
      draft = draft_version_fixture(site)

      {:ok, %{site: site, version: version}} = Scraping.publish_version(site, draft.id)

      assert version.status == "published"
      assert version.published_at
      assert site.current_published_version_id == version.id

      # The pointer must be persisted, not just set on the returned struct.
      reloaded = Repo.reload!(site)
      assert reloaded.current_published_version_id == version.id
    end

    test "supersedes the previous publication atomically" do
      %{site: site, version: first} = published_site_fixture()
      second = draft_version_fixture(site)

      {:ok, %{version: second}} = Scraping.publish_version(site, second.id)
      reloaded_first = Scraping.get_version(first.id)

      assert reloaded_first.status == "superseded"
      assert second.status == "published"
    end

    test "refuses to publish non-draft versions" do
      %{site: site, version: published} = published_site_fixture()

      assert {:error, :not_a_draft} = Scraping.publish_version(site, published.id)
    end

    test "unknown versions error out" do
      site = site_fixture()
      assert {:error, :version_not_found} = Scraping.publish_version(site, 999_999)
    end
  end

  describe "ajax template host restriction (P7-5)" do
    test "rejects a template pointing at a foreign host" do
      site = site_fixture()

      attrs = %{
        "selectors" => %{"chapter_link" => "a", "image_on_chapter_page" => "img"},
        "pagination" => %{
          "type" => "ajax",
          "url_template" => "https://evil.example.test/load?page={page}"
        }
      }

      assert {:error, cs} = Scraping.create_draft_version(site, attrs)
      assert errors_on(cs).config |> List.first() =~ "must point at the site's own host"
    end

    test "accepts a template on the site's own host (case-insensitive)" do
      site = site_fixture()

      attrs = %{
        "selectors" => %{"chapter_link" => "a", "image_on_chapter_page" => "img"},
        "pagination" => %{
          "type" => "ajax",
          "url_template" => "https://#{String.upcase(site.host)}/load?page={page}",
          "max_pages" => 3
        }
      }

      assert {:ok, _version} = Scraping.create_draft_version(site, attrs)
    end
  end

  setup do
    Crysa.Scraping.ConfigCache.invalidate_all()
    :ok
  end

  describe "published_config_for_host/1" do
    test "resolves the typed snapshot for the current published version" do
      %{site: site} = published_site_fixture()

      assert {:ok, %{config: %Config{} = config, version: 1}} =
               Scraping.published_config_for_host(site.host)

      assert config.selectors.chapter_link == "div.chapter-list a"
    end

    test "host lookup is normalized" do
      %{site: site} = published_site_fixture()

      assert {:ok, _} = Scraping.published_config_for_host(String.upcase(site.host))
    end

    test "errors for unknown hosts and unpublished sites" do
      missing = "missing-#{System.unique_integer([:positive])}.example.test"
      assert {:error, :unknown_host} = Scraping.published_config_for_host(missing)

      site = site_fixture()
      _draft = draft_version_fixture(site)

      assert {:error, :no_published_config} = Scraping.published_config_for_host(site.host)
    end

    test "disabled sites are rejected" do
      %{site: site} = published_site_fixture()
      Scraping.update_site(site, %{enabled: false})

      assert {:error, :site_disabled} = Scraping.published_config_for_host(site.host)
    end
  end
end
