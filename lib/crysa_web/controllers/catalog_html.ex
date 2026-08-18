defmodule CrysaWeb.CatalogHTML do
  @moduledoc """
  Pages rendered by CatalogController.
  """

  use CrysaWeb, :html

  import CrysaWeb.CatalogComponents

  embed_templates "catalog_html/*"

  @spec included_categories(map()) :: [String.t()]
  def included_categories(params), do: category_param(params, "category")

  @spec excluded_categories(map()) :: [String.t()]
  def excluded_categories(params), do: category_param(params, "exclude_category")

  @spec format_date(DateTime.t() | nil) :: String.t() | nil
  def format_date(nil), do: nil
  def format_date(%DateTime{} = datetime), do: Calendar.strftime(datetime, "%b %d, %Y")

  defp category_param(%{"exclude_category" => _} = params, "exclude_category"),
    do: split_param(params["exclude_category"])

  defp category_param(_params, "exclude_category"), do: []

  defp category_param(%{"category" => value} = _params, "category"), do: split_param(value)

  defp category_param(_params, "category"), do: []

  defp split_param(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
  end

  defp split_param(value) when is_list(value), do: value

  defp split_param(_), do: []
end
