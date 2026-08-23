defmodule Crysa.Scraping.Config.Pagination do
  @moduledoc """
  Chapter-list pagination namespace of a scraping config document.

  Three forms are supported:

    * `none` — single page (default). The series page holds the full list.
    * `query_param` — iterate `?page=N` style URLs.
    * `ajax` — fetch a separate load-more endpoint whose URL is derived from
      `url_template` by replacing the `{page}` placeholder.

  All iteration forms carry explicit, bounded stop conditions (`max_pages`)
  so a bad config can never loop forever against a target host. Runtime
  iteration additionally stops on empty pages and on pages that yield no new
  chapter keys (see `Crysa.Scraping.Pages`).
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false

  @types ~w(none query_param ajax)
  @max_pages_hard_cap 200

  embedded_schema do
    field :type, :string, default: "none"
    field :param, :string, default: "page"
    field :start, :integer, default: 1
    field :max_pages, :integer, default: 10
    field :url_template, :string
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(pagination, attrs) do
    pagination
    |> cast(attrs, [:type, :param, :start, :max_pages, :url_template])
    |> validate_inclusion(:type, @types)
    |> validate_number(:start, greater_than_or_equal_to: 0)
    |> validate_number(:max_pages,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: @max_pages_hard_cap
    )
    |> validate_length(:param, max: 64)
    |> validate_by_type()
  end

  defp validate_by_type(changeset) do
    case get_field(changeset, :type) do
      "none" -> validate_none(changeset)
      "query_param" -> validate_query_param(changeset)
      "ajax" -> validate_ajax(changeset)
      _ -> changeset
    end
  end

  defp validate_none(changeset) do
    # Iteration fields are meaningless for single-page sites; drop them so the
    # stored document stays minimal and cannot drift into an invalid state.
    changeset
    |> put_change(:param, nil)
    |> put_change(:start, nil)
    |> put_change(:max_pages, nil)
    |> put_change(:url_template, nil)
  end

  defp validate_query_param(changeset) do
    param = get_field(changeset, :param)

    if is_binary(param) and Regex.match?(~r/\A[a-zA-Z0-9_\-]+\z/, param) do
      put_change(changeset, :url_template, nil)
    else
      add_error(changeset, :param, "must be alphanumeric, dash or underscore")
    end
  end

  defp validate_ajax(changeset) do
    template = get_field(changeset, :url_template)

    cond do
      not is_binary(template) or String.trim(template) == "" ->
        add_error(changeset, :url_template, "is required for ajax pagination")

      not valid_template?(String.trim(template)) ->
        add_error(changeset, :url_template, "must be an http(s) URL containing {page}")

      true ->
        put_change(changeset, :url_template, String.trim(template))
    end
  end

  defp valid_template?(template) do
    uri = URI.parse(template)

    uri.scheme in ["http", "https"] and is_binary(uri.host) and
      String.contains?(template, "{page}")
  end
end
