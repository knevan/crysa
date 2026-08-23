defmodule Crysa.Scraping.ConfigTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Crysa.Scraping.Config

  describe "build/1" do
    test "accepts a full valid document" do
      attrs = %{
        "selectors" => %{
          "chapter_link" => "div.chapter-list a",
          "image_on_chapter_page" => "#reader img",
          "title" => "h1.title"
        },
        "chapter_order" => "asc",
        "pagination" => %{
          "type" => "query_param",
          "param" => "page",
          "start" => 1,
          "max_pages" => 20
        },
        "rate_limit" => %{
          "request_delay_ms" => %{"min" => 1_000, "max" => 3_000},
          "image_delay_ms" => %{"min" => 500, "max" => 1_500},
          "max_concurrent_requests" => 4
        }
      }

      assert {:ok, config} = Config.build(attrs)
      assert config.chapter_order == "asc"
      assert config.selectors.chapter_link == "div.chapter-list a"
      assert config.pagination.type == "query_param"
      assert config.rate_limit.max_concurrent_requests == 4
    end

    test "applies safe defaults for missing namespaces" do
      attrs = %{
        "selectors" => %{
          "chapter_link" => "a.chapters",
          "image_on_chapter_page" => "img.page"
        }
      }

      assert {:ok, config} = Config.build(attrs)
      assert config.chapter_order == "desc"
      assert config.pagination.type == "none"
      # rate_limit namespace left empty; Throttle applies code defaults.
      assert is_nil(config.rate_limit.max_concurrent_requests)
    end

    test "rejects invalid selectors" do
      attrs = %{
        "selectors" => %{"chapter_link" => "", "image_on_chapter_page" => "img"}
      }

      assert {:error, cs} = Config.build(attrs)
      assert get_in(errors_on(cs), [:selectors, :chapter_link]) == ["can't be blank"]
    end

    test "rejects selectors with characters outside the CSS allowlist" do
      attrs = %{
        "selectors" => %{"chapter_link" => "a { color: red }", "image_on_chapter_page" => "img"}
      }

      assert {:error, cs} = Config.build(attrs)
      assert get_in(errors_on(cs), [:selectors, :chapter_link])

      # Note: Floki silently ignores unknown selector tokens (e.g. "a >> ["
      # parses as "a"), so semantic correctness is proven by the publish-time
      # test scrape rather than by parseability alone.
    end

    test "rejects oversized delay values and inverted ranges" do
      attrs = %{
        "selectors" => %{"chapter_link" => "a", "image_on_chapter_page" => "img"},
        "rate_limit" => %{"request_delay_ms" => %{"min" => 5_000, "max" => 100}}
      }

      assert {:error, cs} = Config.build(attrs)
      assert errors_on(cs).rate_limit
    end

    test "rejects concurrency above the cap" do
      attrs = %{
        "selectors" => %{"chapter_link" => "a", "image_on_chapter_page" => "img"},
        "rate_limit" => %{"max_concurrent_requests" => 99}
      }

      assert {:error, cs} = Config.build(attrs)
      assert errors_on(cs).rate_limit
    end

    test "ajax pagination requires an http(s) template with {page}" do
      base = %{"selectors" => %{"chapter_link" => "a", "image_on_chapter_page" => "img"}}

      bad =
        Map.put(base, "pagination", %{
          "type" => "ajax",
          "url_template" => "ftp://x.test/load/{page}"
        })

      assert {:error, _cs} = Config.build(bad)

      good =
        Map.put(base, "pagination", %{
          "type" => "ajax",
          "url_template" => "https://x.test/load?page={page}",
          "max_pages" => 3
        })

      assert {:ok, config} = Config.build(good)
      assert config.pagination.url_template == "https://x.test/load?page={page}"
    end

    test "query_param rejects unsafe param names" do
      attrs = %{
        "selectors" => %{"chapter_link" => "a", "image_on_chapter_page" => "img"},
        "pagination" => %{"type" => "query_param", "param" => "page'; drop"}
      }

      assert {:error, cs} = Config.build(attrs)
      assert errors_on(cs).pagination
    end
  end

  describe "to_map/1 + from_map!/2 round trip" do
    test "preserves the document" do
      {:ok, config} =
        Config.build(%{
          "selectors" => %{"chapter_link" => "a.ch", "image_on_chapter_page" => "img.pg"},
          "pagination" => %{"type" => "query_param", "max_pages" => 7}
        })

      map = Config.to_map(config)
      rebuilt = Config.from_map!(map)

      assert Config.checksum(config) == Config.checksum(rebuilt)
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
