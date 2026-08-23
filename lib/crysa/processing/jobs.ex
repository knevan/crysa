defmodule Crysa.Processing.Jobs do
  @moduledoc """
  Oban job definitions for scraping and processing work.

  All jobs are idempotent and safe to retry. Workers resolve the published
  scraping config snapshot at job start (snapshot semantics: config changes
  affect newly enqueued jobs only).
  """

  @moduledoc since: "0.1.0"
end
