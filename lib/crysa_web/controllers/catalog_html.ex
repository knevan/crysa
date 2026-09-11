defmodule CrysaWeb.CatalogHTML do
  @moduledoc """
  Pages rendered by CatalogController.
  """

  use CrysaWeb, :html

  import CrysaWeb.CatalogComponents

  embed_templates "catalog_html/*"

  @spec format_date(DateTime.t() | nil) :: String.t() | nil
  def format_date(nil), do: nil
  def format_date(%DateTime{} = datetime), do: Calendar.strftime(datetime, "%b %d, %Y")
end
