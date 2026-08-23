defmodule Crysa.Scraping.FetcherTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias Crysa.Scraping.Fetcher

  @url "https://fetcher-test.example.test/page"
  @opts [
    rate_limit: :skip,
    req_opts: [plug: {Req.Test, FetcherTest}]
  ]

  describe "fetch_html/2" do
    test "returns the body on success" do
      Req.Test.stub(FetcherTest, fn conn ->
        Plug.Conn.send_resp(conn, 200, "<html>ok</html>")
      end)

      assert {:ok, "<html>ok</html>"} = Fetcher.fetch_html(@url, @opts)
    end

    test "classifies 404 as a permanent status error" do
      Req.Test.stub(FetcherTest, fn conn ->
        Plug.Conn.send_resp(conn, 404, "nope")
      end)

      opts = Keyword.merge(@opts, retries: 0)

      assert {:error, %Fetcher.Error{reason: :status_error, status: 404}} =
               Fetcher.fetch_html(@url, opts)
    end

    test "retries transient 5xx responses and eventually succeeds" do
      counter = :counters.new(1, [:atomics])

      Req.Test.stub(FetcherTest, fn conn ->
        n = :counters.get(counter, 1)
        :counters.add(counter, 1, 1)

        if n < 2 do
          Plug.Conn.send_resp(conn, 503, "busy")
        else
          Plug.Conn.send_resp(conn, 200, "<html>recovered</html>")
        end
      end)

      opts = Keyword.merge(@opts, retries: 3, backoff_base_ms: 1)

      assert {:ok, "<html>recovered</html>"} = Fetcher.fetch_html(@url, opts)
      assert :counters.get(counter, 1) == 3
    end

    test "does not retry permanent 4xx responses" do
      counter = :counters.new(1, [:atomics])

      Req.Test.stub(FetcherTest, fn conn ->
        :counters.add(counter, 1, 1)
        Plug.Conn.send_resp(conn, 404, "gone")
      end)

      opts = Keyword.merge(@opts, retries: 3, backoff_base_ms: 1)

      assert {:error, %Fetcher.Error{reason: :status_error}} = Fetcher.fetch_html(@url, opts)
      assert :counters.get(counter, 1) == 1
    end

    test "halts oversized bodies" do
      Req.Test.stub(FetcherTest, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/html")
        |> Plug.Conn.send_resp(200, String.duplicate("x", 100))
      end)

      opts = Keyword.merge(@opts, html_max_bytes: 10)

      assert {:error, %Fetcher.Error{reason: :body_too_large}} = Fetcher.fetch_html(@url, opts)
    end
  end

  describe "fetch_bytes/2" do
    test "returns raw binary content without decoding" do
      png = <<0x89, 0x50, 0x4E, 0x47, 1, 2, 3>>

      Req.Test.stub(FetcherTest, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("image/png")
        |> Plug.Conn.send_resp(200, png)
      end)

      assert {:ok, ^png} = Fetcher.fetch_bytes(@url, @opts)
    end
  end

  describe "throttle slot lifecycle" do
    @rl %Crysa.Scraping.Config.RateLimit{
      request_delay_ms: %{min: 10, max: 10},
      image_delay_ms: %{min: 10, max: 10},
      max_concurrent_requests: 1
    }

    test "releases the concurrency slot after each fetch" do
      Req.Test.stub(FetcherTest, fn conn ->
        Plug.Conn.send_resp(conn, 200, "<html>ok</html>")
      end)

      opts = [rate_limit: @rl, req_opts: [plug: {Req.Test, FetcherTest}]]
      host = "fetcher-test.example.test"

      # Sequential fetches with max_concurrent_requests: 1 must never wedge —
      # this is the regression guard for the acquire-without-release leak.
      Enum.each(1..5, fn _ ->
        assert {:ok, "<html>ok</html>"} = Fetcher.fetch_html("https://#{host}/p", opts)
        entry = Map.get(Crysa.Scraping.Throttle.snapshot(), host)
        assert entry == nil or entry.active == 0
      end)
    end

    test "releases the slot even when the fetch fails" do
      Req.Test.stub(FetcherTest, fn conn ->
        Plug.Conn.send_resp(conn, 404, "gone")
      end)

      opts = Keyword.merge([rate_limit: @rl], retries: 0)
      opts = Keyword.put(opts, :req_opts, plug: {Req.Test, FetcherTest})
      host = "fetcher-test.example.test"

      assert {:error, %Fetcher.Error{}} = Fetcher.fetch_html("https://#{host}/x", opts)
      entry = Map.get(Crysa.Scraping.Throttle.snapshot(), host)
      assert entry == nil or entry.active == 0
    end
  end

  describe "fetch_many/2" do
    test "collects all bytes in order and stops at first failure" do
      Req.Test.stub(FetcherTest, fn conn ->
        case conn.path_info do
          ["a"] -> Plug.Conn.send_resp(conn, 200, "AAA")
          ["b"] -> Plug.Conn.send_resp(conn, 200, "BBB")
          _ -> Plug.Conn.send_resp(conn, 500, "boom")
        end
      end)

      base = "https://fetcher-test.example.test"
      opts = Keyword.merge(@opts, retries: 0)

      assert {:ok, ["AAA", "BBB"]} =
               Fetcher.fetch_many([base <> "/a", base <> "/b"], opts)

      assert {:error, %Fetcher.Error{reason: :transient}} =
               Fetcher.fetch_many([base <> "/a", base <> "/c", base <> "/b"], opts)
    end
  end
end
