defmodule PlugboardWeb.PageHTMLTest do
  use PlugboardWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  describe "home/1" do
    test "renders the home page template successfully" do
      assigns = %{flash: %{}}
      html = PlugboardWeb.PageHTML.home(assigns)
      assert %Phoenix.LiveView.Rendered{} = html
    end

    test "home page contains Phoenix branding and version" do
      assigns = %{flash: %{}}
      html = rendered_to_string(PlugboardWeb.PageHTML.home(assigns))

      assert html =~ "Phoenix Framework"
      assert html =~ "Peace of mind from prototype to production"
    end

    test "home page contains documentation links" do
      assigns = %{flash: %{}}
      html = rendered_to_string(PlugboardWeb.PageHTML.home(assigns))

      assert html =~ "Guides &amp; Docs"
      assert html =~ "https://hexdocs.pm/phoenix/overview.html"
      assert html =~ "Source Code"
      assert html =~ "https://github.com/phoenixframework/phoenix"
    end

    test "home page contains community links" do
      assigns = %{flash: %{}}
      html = rendered_to_string(PlugboardWeb.PageHTML.home(assigns))

      assert html =~ "Discuss on the Elixir Forum"
      assert html =~ "https://elixirforum.com"
      assert html =~ "Join our Discord server"
      assert html =~ "https://discord.gg/elixir"
      assert html =~ "Join us on Slack"
      assert html =~ "https://elixir-slack.community"
    end

    test "home page contains deployment information" do
      assigns = %{flash: %{}}
      html = rendered_to_string(PlugboardWeb.PageHTML.home(assigns))

      assert html =~ "Deploy your application"
      assert html =~ "https://fly.io/docs/elixir/getting-started"
    end

    test "home page renders flash group component" do
      assigns = %{flash: %{}}
      html = rendered_to_string(PlugboardWeb.PageHTML.home(assigns))

      # Verify flash component is included
      assert html =~ "flash"
    end
  end
end
