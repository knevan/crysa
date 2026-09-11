defmodule CrysaWeb.PageControllerTest do
  use CrysaWeb.ConnCase

  defmodule StubSSR do
    @moduledoc false
    @behaviour LiveVue.SSR

    @impl true
    def render(_name, _props, _slots), do: "<!-- preload -->SSR-STUB-TRENDING"
  end

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    body = html_response(conn, 200)
    assert body =~ "New Series"
    assert body =~ "TrendingSection"
  end

  test "trending island is server-rendered on first paint", %{conn: conn} do
    previous = Application.get_env(:live_vue, :ssr_module)
    Application.put_env(:live_vue, :ssr_module, StubSSR)

    try do
      body = conn |> get(~p"/") |> html_response(200)
      assert body =~ "SSR-STUB-TRENDING"
    after
      if is_nil(previous),
        do: Application.delete_env(:live_vue, :ssr_module),
        else: Application.put_env(:live_vue, :ssr_module, previous)
    end
  end
end
