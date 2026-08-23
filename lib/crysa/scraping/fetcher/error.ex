defmodule Crysa.Scraping.Fetcher.Error do
  @moduledoc """
  Structured fetch failure returned by `Crysa.Scraping.Fetcher`.

  `reason` drives retry policy and durable `last_error` bookkeeping:

    * `:transient` — 5xx / 429 responses.
    * `:timeout` — receive/connect timeout.
    * `:connect` — transport-level failures (refused, closed, DNS).
    * `:status_error` — non-retryable HTTP status (4xx).
    * `:body_too_large` — response exceeded the configured byte cap.
    * `:permanent` — anything else (invalid URL, protocol errors).
  """

  defexception [:kind, :reason, :status, :url, :message]

  @type t :: %__MODULE__{}

  def message(%__MODULE__{} = err) do
    status_part = if err.status, do: " status=#{err.status}", else: ""
    "#{err.kind} fetch failed for #{err.url}:#{status_part} #{err.reason} (#{err.message})"
  end
end
