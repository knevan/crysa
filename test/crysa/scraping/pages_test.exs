defmodule Crysa.Scraping.PagesTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Crysa.Scraping.{Config, Pages}

  defp config(pagination) do
    {:ok, config} =
      Config.build(%{
        "selectors" => %{"chapter_link" => "a", "image_on_chapter_page" => "img"},
        "pagination" => pagination
      })

    config
  end

  test "none yields only the series page" do
    cfg = config(%{"type" => "none"})
    assert Pages.page_urls("https://x.test/s/1", cfg) == ["https://x.test/s/1"]
  end

  test "query_param appends successive pages preserving existing query" do
    cfg = config(%{"type" => "query_param", "param" => "page", "start" => 1, "max_pages" => 3})

    urls = Pages.page_urls("https://x.test/s/1?lang=en", cfg)

    assert [
             "https://x.test/s/1?lang=en",
             page2,
             page3
           ] = urls

    assert page2 =~ "page=2"
    assert page2 =~ "lang=en"
    assert page3 =~ "page=3"
  end

  test "query_param honours a non-1 start" do
    cfg = config(%{"type" => "query_param", "start" => 5, "max_pages" => 2})
    [_first, second] = Pages.page_urls("https://x.test/s/1", cfg)
    assert second =~ "page=6"
  end

  test "ajax expands the template" do
    cfg =
      config(%{
        "type" => "ajax",
        "url_template" => "https://x.test/api/load?page={page}",
        "max_pages" => 2
      })

    [_series, ajax1] = Pages.page_urls("https://x.test/s/1", cfg)

    # Series page counts as page 1; load-more starts at page 2.
    assert ajax1 == "https://x.test/api/load?page=2"
  end

  test "total URLs are bounded by max_pages for every type" do
    for pagination <- [
          %{"type" => "none"},
          %{"type" => "query_param", "param" => "page", "start" => 1, "max_pages" => 4},
          %{
            "type" => "ajax",
            "url_template" => "https://x.test/l?p={page}",
            "start" => 1,
            "max_pages" => 4
          }
        ] do
      urls = Pages.page_urls("https://x.test/s/1", config(pagination))
      assert Enum.count_until(urls, 5) <= 4
    end
  end
end
