defmodule PlugboardWeb.ErrorHTMLTest do
  use PlugboardWeb.ConnCase, async: true

  # Bring render_to_string/4 for testing custom views
  import Phoenix.Template, only: [render_to_string: 4]

  describe "error pages" do
    test "renders 404 Not Found" do
      result = render_to_string(PlugboardWeb.ErrorHTML, "404", "html", [])
      assert result == "Not Found"
      assert is_binary(result)
    end

    test "renders 500 Internal Server Error" do
      result = render_to_string(PlugboardWeb.ErrorHTML, "500", "html", [])
      assert result == "Internal Server Error"
      assert is_binary(result)
    end

    test "renders 403 Forbidden" do
      result = render_to_string(PlugboardWeb.ErrorHTML, "403", "html", [])
      assert result == "Forbidden"
      assert is_binary(result)
    end

    test "renders 401 Unauthorized" do
      result = render_to_string(PlugboardWeb.ErrorHTML, "401", "html", [])
      assert result == "Unauthorized"
      assert is_binary(result)
    end

    test "renders 422 Unprocessable Entity" do
      result = render_to_string(PlugboardWeb.ErrorHTML, "422", "html", [])
      assert result == "Unprocessable Entity"
      assert is_binary(result)
    end

    test "renders 503 Service Unavailable" do
      result = render_to_string(PlugboardWeb.ErrorHTML, "503", "html", [])
      assert result == "Service Unavailable"
      assert is_binary(result)
    end

    test "renders any other error code with appropriate message" do
      result = render_to_string(PlugboardWeb.ErrorHTML, "418", "html", [])
      # Phoenix.Controller.status_message_from_template returns HTML-escaped strings
      assert result == "I&#39;m a teapot"
      assert is_binary(result)
    end

    test "render function always returns a string" do
      for status <- ["404", "500", "403", "401"] do
        result = render_to_string(PlugboardWeb.ErrorHTML, status, "html", [])
        assert is_binary(result)
        assert String.length(result) > 0
      end
    end
  end
end
