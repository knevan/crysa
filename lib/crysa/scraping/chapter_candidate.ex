defmodule Crysa.Scraping.ChapterCandidate do
  @moduledoc """
  A single chapter link discovered by the parser.

  Replaces Castra's float-based `%ChapterInfo{number: f32}` with the canonical
  identity model decided in the plan:

    * `chapter_key` — canonical source-aware identity used for deduplication
      and the unique `(series_id, chapter_key)` constraint.
    * `display_number` — user-facing label.
    * `chapter_number` — optional `Decimal` helper, present only when the
      chapter is purely numeric; never the source of truth.
    * `sort_key` — fixed-width sortable representation generated here so
      ordering never depends on float comparison.
  """

  @type t :: %__MODULE__{
          url: String.t(),
          title: String.t() | nil,
          chapter_key: String.t(),
          display_number: String.t(),
          chapter_number: Decimal.t() | nil,
          sort_key: String.t()
        }

  defstruct [:url, :title, :chapter_key, :display_number, :chapter_number, :sort_key]

  @doc """
  Builds a candidate from parsed components.

  * `numeric` — `{"10", "5"}` style `{major, minor}` digit strings, or
    `{major, suffix}` when a non-numeric suffix was matched.
  """
  @spec build(String.t(), String.t() | nil, {String.t(), String.t()}) :: t()
  def build(url, title, {major, minor}) when is_binary(major) do
    cond do
      whole_number?(minor) ->
        %__MODULE__{
          url: url,
          title: title,
          chapter_key: major,
          display_number: major,
          chapter_number: Decimal.new(major),
          sort_key: sort_key(major, "000", "")
        }

      numeric_minor?(minor) ->
        key = "#{major}.#{minor}"

        %__MODULE__{
          url: url,
          title: title,
          chapter_key: key,
          display_number: key,
          chapter_number: to_decimal(major, minor),
          sort_key: sort_key(major, minor, "")
        }

      true ->
        key = "#{major}-#{minor}"

        %__MODULE__{
          url: url,
          title: title,
          chapter_key: key,
          display_number: key,
          chapter_number: nil,
          sort_key: sort_key(major, "000", minor)
        }
    end
  end

  defp numeric_minor?(minor), do: Regex.match?(~r/\A\d+\z/, minor)
  defp whole_number?(minor), do: minor == "000"

  defp to_decimal(major, minor) do
    # Fractional digits beyond the DB scale (12,3) are rejected upstream, so
    # this conversion cannot fail for validated input.
    Decimal.new("#{major}.#{minor}")
  end

  defp sort_key(major, minor, suffix) do
    padded_major = String.pad_leading(major, 6, "0")
    padded_minor = String.pad_leading(minor, 3, "0")
    "#{padded_major}.#{padded_minor}.#{suffix}"
  end
end
