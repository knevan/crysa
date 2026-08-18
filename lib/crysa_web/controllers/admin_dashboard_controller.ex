defmodule CrysaWeb.AdminDashboardController do
  @moduledoc """
  Admin dashboard placeholder. Admin features land in Phase 8.
  """

  use CrysaWeb, :controller

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    render(conn, :index)
  end
end
