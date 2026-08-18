defmodule CrysaWeb.ModeratorDashboardController do
  @moduledoc """
  Moderator dashboard placeholder. Moderation features land in Phase 5/8.
  """

  use CrysaWeb, :controller

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    render(conn, :index)
  end
end
