defmodule Crysa.Scraping.Fetcher do
  @moduledoc """
  Outbound HTTP fetching for scraping jobs, built on `Req`.

  Port of Castra's `scraping/fetcher.rs` with the plan's latency-budget
  requirements applied:

    * Every attempt passes through the per-host gate
      (`Crysa.Scraping.Throttle.acquire/3`) before hitting the network.
      Pass `rate_limit: :skip` to bypass throttling (tests, trusted fetches).
    * Retry classification stays in code: transient = 5xx, 429, timeouts,
      connect errors; everything else fails fast.
    * Exponential backoff with random jitter between attempts.
    * Explicit total latency budget: connect timeout, receive timeout,
      redirect limit and a hard response-body size cap (the streamed read is
      halted as soon as the cap is exceeded).
    * Telemetry span `[:crysa, :scraping, :fetch]` around each call.

  Per-host outbound proxy support (Castra's `dynamic_proxy`, itself an empty
  placeholder upstream) is deliberately deferred until proxy pools are a
  real operational requirement; when added it belongs in the site config's
  rate-limit/proxy namespace and plugs into `req_opts` here.

  Tests inject responses via `Req.Test` using the `:req_opts` passthrough
  (e.g. `req_opts: [plug: {Req.Test, MyKey}]`).
  """

  require Logger

  alias Crysa.Scraping.Fetcher.Error
  alias Crysa.Scraping.Throttle

  @type kind :: :html | :bytes
  @type config :: %{
          optional(:retries) => non_neg_integer(),
          optional(:receive_timeout) => pos_integer(),
          optional(:connect_timeout) => pos_integer(),
          optional(:max_redirects) => non_neg_integer(),
          optional(:html_max_bytes) => pos_integer(),
          optional(:image_max_bytes) => pos_integer(),
          optional(:backoff_base_ms) => pos_integer(),
          optional(:user_agent) => String.t(),
          optional(:rate_limit) => Crysa.Scraping.Config.RateLimit.t() | :skip,
          optional(:req_opts) => keyword()
        }

  @spec defaults() :: config()
  defp defaults do
    %{
      retries: 3,
      receive_timeout: 15_000,
      connect_timeout: 10_000,
      max_redirects: 3,
      html_max_bytes: 5 * 1024 * 1024,
      image_max_bytes: 15 * 1024 * 1024,
      backoff_base_ms: 500,
      user_agent: "CrysA/0.1 (+https://crysa.example/bot)"
    }
  end

  # -- Public API ---------------------------------------------------------------

  @doc "Fetches a page as an HTML string."
  @spec fetch_html(String.t(), keyword()) :: {:ok, String.t()} | {:error, Error.t()}
  def fetch_html(url, opts \\ []) do
    fetch(url, Keyword.put(opts, :kind, :html))
  end

  @doc "Fetches binary content (chapter images)."
  @spec fetch_bytes(String.t(), keyword()) :: {:ok, binary()} | {:error, Error.t()}
  def fetch_bytes(url, opts \\ []) do
    fetch(url, Keyword.put(opts, :kind, :bytes))
  end

  @doc """
  Fetches a sequence of URLs sequentially. Stops at the first failure;
  transient failures are retried internally per URL.
  """
  @spec fetch_many([String.t()], keyword()) ::
          {:ok, [binary()]} | {:error, Error.t()}
  def fetch_many(urls, opts) when is_list(urls) do
    urls
    |> Enum.reduce_while({:ok, []}, fn url, {:ok, acc} ->
      case fetch_bytes(url, opts) do
        {:ok, bytes} -> {:cont, {:ok, [bytes | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      err -> err
    end
  end

  # -- Core -----------------------------------------------------------------------

  defp fetch(url, opts) do
    cfg = Map.merge(defaults(), Map.new(opts))
    kind = Map.fetch!(cfg, :kind)
    extra_req_opts = Map.get(cfg, :req_opts, [])
    meta = %{host: host_of(url), kind: kind}

    :telemetry.span([:crysa, :scraping, :fetch], meta, fn ->
      result = fetch_with_retries(url, kind, cfg, extra_req_opts, 0)

      result_meta =
        case result do
          {:ok, body} -> Map.put(meta, :byte_size, byte_size(body))
          {:error, %Error{} = err} -> Map.merge(meta, %{reason: err.reason, status: err.status})
        end

      {result, result_meta}
    end)
  end

  defp fetch_with_retries(url, kind, cfg, extra_req_opts, attempt) do
    maybe_throttled(url, cfg, kind, fn ->
      handle_attempt(url, kind, cfg, extra_req_opts, attempt)
    end)
  end

  defp handle_attempt(url, kind, cfg, extra_req_opts, attempt) do
    case request(url, kind, cfg, extra_req_opts) do
      {:ok, _body} = ok ->
        ok

      {:error, %Error{reason: reason} = err} ->
        retry_or_fail(url, kind, cfg, extra_req_opts, attempt, reason, err)
    end
  end

  defp retry_or_fail(url, kind, cfg, extra_req_opts, attempt, reason, err) do
    if transient?(reason) and attempt < cfg.retries do
      sleep_backoff(cfg.backoff_base_ms, attempt)

      Logger.warning("scraper fetch retrying",
        host: host_of(url),
        attempt: attempt + 1,
        reason: reason
      )

      fetch_with_retries(url, kind, cfg, extra_req_opts, attempt + 1)
    else
      {:error, err}
    end
  end

  # Runs `fun` under the per-host gate. The concurrency slot MUST be released
  # on every path — including retries and failures — or long-lived Oban jobs
  # would wedge the host queue after max_concurrent requests.
  defp maybe_throttled(url, cfg, kind, fun) do
    case Map.get(cfg, :rate_limit) do
      nil ->
        fun.()

      :skip ->
        fun.()

      rate_limit ->
        # Image downloads use their own (typically shorter) delay range.
        throttle_kind = if kind == :bytes, do: :image, else: :page
        host = host_of(url)
        Throttle.acquire(host, rate_limit, throttle_kind)

        try do
          fun.()
        after
          Throttle.release(host)
        end
    end
  end

  defp request(url, kind, cfg, extra_req_opts) do
    req_opts =
      [
        headers: [{"user-agent", cfg.user_agent}],
        retry: false,
        redirect: true,
        max_redirects: cfg.max_redirects,
        connect_options: [timeout: cfg.connect_timeout],
        receive_timeout: cfg.receive_timeout,
        decode_body: false,
        into: bounded_collector(max_bytes(kind, cfg))
      ]
      |> Keyword.merge(extra_req_opts)

    try do
      case Req.get(url, req_opts) do
        {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
          limit = max_bytes(kind, cfg)

          if byte_size(body) > limit do
            # The streamed read already halted early; this is the final guard.
            {:error, build_error(url, kind, :body_too_large, status, "body exceeded limit")}
          else
            {:ok, body}
          end

        {:ok, %Req.Response{status: status}} ->
          {:error, build_error(url, kind, classify_status(status), status, "http error")}

        {:error, exception} ->
          {:error, build_error(url, kind, classify_exception(exception), nil, exception)}
      end
    rescue
      e in [Req.TransportError, Req.HTTPError] ->
        {:error, build_error(url, kind, classify_exception(e), nil, e)}

      e ->
        {:error, build_error(url, kind, :permanent, nil, e)}
    end
  end

  defp max_bytes(:html, cfg), do: cfg.html_max_bytes
  defp max_bytes(_kind, cfg), do: cfg.image_max_bytes

  # Accumulates streamed chunks into the response body and halts the read as
  # soon as the cap is exceeded. The `into: fun` contract passes an
  # `{request, response}` accumulator.
  defp bounded_collector(max_bytes) do
    fn
      {:data, data}, {request, %Req.Response{} = response} ->
        new_body = if is_binary(response.body), do: response.body <> data, else: data
        response = %Req.Response{response | body: new_body}

        if byte_size(new_body) > max_bytes do
          {:halt, {request, response}}
        else
          {:cont, {request, response}}
        end

      _other, acc ->
        {:cont, acc}
    end
  end

  # -- Classification -------------------------------------------------------------

  defp classify_status(429), do: :transient
  defp classify_status(status) when status >= 500, do: :transient
  defp classify_status(_status), do: :status_error

  defp classify_exception(%Req.DecompressError{}), do: :transient

  # Timeouts surface as TransportError with reason :timeout in Req.
  defp classify_exception(%Req.TransportError{reason: reason}) do
    case reason do
      :nxdomain -> :permanent
      :timeout -> :timeout
      _ -> :connect
    end
  end

  defp classify_exception(%Req.HTTPError{reason: reason}) do
    if reason in [:timeout, :closed, :econnrefused], do: :transient, else: :permanent
  end

  defp classify_exception(_), do: :permanent

  defp transient?(:transient), do: true
  defp transient?(:timeout), do: true
  defp transient?(:connect), do: true
  defp transient?(_), do: false

  # -- Errors / misc ------------------------------------------------------------------

  defp build_error(url, kind, reason, status, exception_or_message) do
    message =
      case exception_or_message do
        %_{} = e -> Exception.message(e)
        other -> to_string(other)
      end

    Error.exception(kind: kind, reason: reason, status: status, url: url, message: message)
  end

  defp sleep_backoff(base_ms, attempt) do
    exp = base_ms * Integer.pow(2, attempt)
    jitter = max(div(exp, 4), 1)
    Process.sleep(exp + Enum.random(-jitter..jitter))
  end

  defp host_of(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) -> String.downcase(host)
      _ -> "unknown"
    end
  end
end
