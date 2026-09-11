defmodule CrysaWeb.PageController do
  use CrysaWeb, :controller

  alias Crysa.Catalog
  alias Crysa.Trending

  def home(conn, params) do
    {series, pagination} = Catalog.list_new_series(params)

    render(conn, :home,
      page_title: "Trending",
      series: series,
      pagination: pagination,
      params: params,
      trending: Trending.trending_lists()
    )
  end
end
