defmodule PlugboardWeb.PageHTMLTest do
  use PlugboardWeb.ConnCase, async: true

  test "home template renders" do
    assigns = %{}
    html = PlugboardWeb.PageHTML.home(assigns)
    assert %Phoenix.LiveView.Rendered{} = html
  end
end
