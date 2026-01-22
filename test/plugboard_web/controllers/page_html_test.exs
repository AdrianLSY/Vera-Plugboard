defmodule PlugboardWeb.PageHTMLTest do
  use PlugboardWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  describe "home/1" do
    test "renders the home page template successfully" do
      assigns = %{flash: %{}}
      html = PlugboardWeb.PageHTML.home(assigns)
      assert %Phoenix.LiveView.Rendered{} = html
    end

    test "home page renders the layout with sidebar and main content area" do
      assigns = %{flash: %{}}
      html = rendered_to_string(PlugboardWeb.PageHTML.home(assigns))

      # The home page renders the layout with sidebar and main content
      assert html =~ ~s(id="flash-group")
      assert html =~ ~s(class="flex")
      assert html =~ ~s(<main)
    end

    test "home page does not contain specific documentation links" do
      assigns = %{flash: %{}}
      html = rendered_to_string(PlugboardWeb.PageHTML.home(assigns))

      # Content was removed from home page
      refute html =~ "Guides &amp; Docs"
      refute html =~ "https://hexdocs.pm/phoenix/overview.html"
    end

    test "home page does not contain community links" do
      assigns = %{flash: %{}}
      html = rendered_to_string(PlugboardWeb.PageHTML.home(assigns))

      # Content was removed from home page
      refute html =~ "Discuss on the Elixir Forum"
      refute html =~ "https://elixirforum.com"
    end

    test "home page does not contain deployment information" do
      assigns = %{flash: %{}}
      html = rendered_to_string(PlugboardWeb.PageHTML.home(assigns))

      # Content was removed from home page
      refute html =~ "Deploy your application"
    end

    test "home page renders flash group component" do
      assigns = %{flash: %{}}
      html = rendered_to_string(PlugboardWeb.PageHTML.home(assigns))

      # Verify flash component is included
      assert html =~ "flash"
    end
  end
end
