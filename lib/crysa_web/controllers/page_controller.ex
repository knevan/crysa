defmodule CrysaWeb.PageController do
  use CrysaWeb, :controller

  alias Crysa.Catalog

  def home(conn, params) do
    {series, pagination} = Catalog.list_new_series(params)

    render(conn, :home,
      page_title: "New Series",
      series: series,
      pagination: pagination,
      params: params
    )
  end
end
