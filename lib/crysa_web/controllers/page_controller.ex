defmodule CrysaWeb.PageController do
  use CrysaWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
