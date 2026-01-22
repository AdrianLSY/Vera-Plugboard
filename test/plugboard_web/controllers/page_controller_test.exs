defmodule PlugboardWeb.PageControllerTest do
  use PlugboardWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    response = html_response(conn, 200)

    # The home page renders the layout with basic structure
    assert response =~ ~s(id="flash-group")
    assert response =~ ~s(<main)
  end
end
