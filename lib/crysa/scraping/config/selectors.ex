defmodule Crysa.Scraping.Config.Selectors do
  @moduledoc """
  CSS selector namespace of a scraping config document.

  `chapter_link` and `image_on_chapter_page` are required; the metadata
  selectors (`title`, `cover`, `description`) are optional and used by the
  series import path. Every selector is validated against a strict charset
  allowlist, a length bound and CSS parseability via `Floki.Selector.Parser`.

  Floki silently ignores unknown selector tokens (e.g. `div >> bad[[[` parses
  as `div`), so parseability alone does not prove semantic correctness — that
  is the job of the publish-time test scrape.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false

  @max_selector_length 256

  # Conservative allowlist covering common CSS selector syntax: type/id/class,
  # attribute selectors with string values, combinators, pseudo-classes and
  # structural pseudo-functions such as nth-child(2n+1).
  @selector_charset ~r/\A[a-zA-Z0-9\s\-\_\.#\[\]\=\>"'():>\*\,\+\~\|\^\$\@%]+\z/

  embedded_schema do
    field :chapter_link, :string
    field :image_on_chapter_page, :string
    field :title, :string
    field :cover, :string
    field :description, :string
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(selectors, attrs) do
    selectors
    |> cast(attrs, [:chapter_link, :image_on_chapter_page, :title, :cover, :description])
    |> validate_required([:chapter_link, :image_on_chapter_page])
    |> validate_each_selector([
      :chapter_link,
      :image_on_chapter_page,
      :title,
      :cover,
      :description
    ])
  end

  defp validate_each_selector(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, acc ->
      case fetch_change(acc, field) do
        {:ok, value} -> validate_selector(acc, field, value)
        :error -> acc
      end
    end)
  end

  defp validate_selector(changeset, field, value) do
    trimmed = String.trim(value)
    byte_size = byte_size(trimmed)

    cond do
      byte_size == 0 ->
        add_error(changeset, field, "cannot be blank")

      byte_size > @max_selector_length ->
        add_error(changeset, field, "must be at most #{@max_selector_length} characters")

      not Regex.match?(@selector_charset, trimmed) ->
        add_error(changeset, field, "contains characters not allowed in a CSS selector")

      not parseable?(trimmed) ->
        add_error(changeset, field, "is not a parseable CSS selector")

      true ->
        put_change(changeset, field, trimmed)
    end
  end

  @spec parseable?(String.t()) :: boolean()
  defp parseable?(selector) do
    case safe_parse(selector) do
      {:ok, [%Floki.Selector{} | _]} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp safe_parse(selector) do
    {:ok, Floki.Selector.Parser.parse(selector)}
  rescue
    e -> {:error, e}
  catch
    _, _ -> {:error, :parse_failure}
  end
end
