defmodule PlugboardWeb.ErrorHTMLTest do
  use PlugboardWeb.ConnCase, async: true

  # Bring render_to_string/4 for testing custom views
  import Phoenix.Template, only: [render_to_string: 4]

  test "renders 404.html" do
    assert render_to_string(PlugboardWeb.ErrorHTML, "404", "html", []) == "Not Found"
  end

  test "renders 500.html" do
    assert render_to_string(PlugboardWeb.ErrorHTML, "500", "html", []) == "Internal Server Error"
  end

  test "renders 403.html" do
    assert render_to_string(PlugboardWeb.ErrorHTML, "403", "html", []) == "Forbidden"
  end

  test "renders any other error template" do
    assert render_to_string(PlugboardWeb.ErrorHTML, "503", "html", []) == "Service Unavailable"
  end
end
