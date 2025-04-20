defmodule PlugboardWeb.ServiceLiveTest do
  use PlugboardWeb.ConnCase

  alias Plugboard.Services.Services

  import Phoenix.LiveViewTest
  import Plugboard.ServicesFixtures

  @create_attrs %{name: "some name"}
  @update_attrs %{name: "some updated name"}
  @invalid_attrs %{name: nil}
  @create_child_attrs %{name: "child service"}

  defp create_service(_) do
    service = service_fixture()
    %{service: service}
  end

  defp create_service_with_child(_) do
    parent = service_fixture()
    child = service_fixture(%{parent_id: parent.id})
    %{parent: parent, child: child}
  end

  describe "Index" do
    setup [:create_service]

    test "lists all root services", %{conn: conn, service: service} do
      {:ok, _index_live, html} = live(conn, ~p"/services")

      assert html =~ "Services"
      assert html =~ service.name
    end

    test "doesn't list child services on index", %{conn: conn, service: parent} do
      child = service_fixture(%{parent_id: parent.id})
      {:ok, _index_live, html} = live(conn, ~p"/services")

      assert html =~ parent.name
      refute html =~ child.name
    end

    test "saves new service", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/services")

      assert index_live |> element("a", "Create Service") |> render_click() =~
        "New Service"

      assert_patch(index_live, ~p"/services/new")

      assert index_live
        |> form("#service-form", service: @invalid_attrs)
        |> render_change() =~ "can&#39;t be blank"

      html = index_live
        |> form("#service-form", service: @create_attrs)
        |> render_submit()

      assert html =~ "Service created"
      assert html =~ "some name"
    end

    test "updates service in listing", %{conn: conn, service: service} do
      {:ok, index_live, _html} = live(conn, ~p"/services")

      assert index_live |> element("#services-#{service.id} a", "Edit") |> render_click() =~
        "Edit Service"

      assert_patch(index_live, ~p"/services/#{service}/edit")

      assert index_live
        |> form("#service-form", service: @invalid_attrs)
        |> render_change() =~ "can&#39;t be blank"

      # First render the form submission
      index_live
      |> form("#service-form", service: @update_attrs)
      |> render_submit()

      # Then wait a brief moment and re-render to see the updated content
      Process.sleep(100)
      html = render(index_live)
      assert html =~ "Service updated"
      assert html =~ "some updated name"
    end

    test "deletes service in listing", %{conn: conn, service: service} do
      {:ok, index_live, _html} = live(conn, ~p"/services")

      assert index_live |> element("#services-#{service.id} a", "Delete") |> render_click()
      refute has_element?(index_live, "#services-#{service.id}")
    end
  end

  describe "Show" do
    setup [:create_service_with_child]

    test "displays service and its children", %{conn: conn, parent: parent, child: child} do
      {:ok, _show_live, html} = live(conn, ~p"/services/#{parent}")

      assert html =~ parent.name
      assert html =~ child.name
    end

    test "creates new child service", %{conn: conn, parent: parent} do
      {:ok, show_live, _html} = live(conn, ~p"/services/#{parent}")

      assert show_live |> element("a", "Create Service") |> render_click() =~
        "New Service"

      assert_patch(show_live, ~p"/services/#{parent}/new")

      assert show_live
        |> form("#service-form", service: @invalid_attrs)
        |> render_change() =~ "can&#39;t be blank"

      html = show_live
        |> form("#service-form", service: @create_child_attrs)
        |> render_submit()

      assert html =~ "Service created"
      assert html =~ "child service"
    end

    test "updates child service", %{conn: conn, parent: parent, child: child} do
      {:ok, show_live, _html} = live(conn, ~p"/services/#{parent}")

      assert show_live |> element("#services-#{child.id} a", "Edit") |> render_click() =~
        "Edit Service"

      assert_patch(show_live, ~p"/services/#{parent}/edit/#{child.id}")

      assert show_live
        |> form("#service-form", service: @invalid_attrs)
        |> render_change() =~ "can&#39;t be blank"

      html = show_live
        |> form("#service-form", service: @update_attrs)
        |> render_submit()

      assert html =~ "Service updated"
      assert html =~ "some updated name"
    end

    test "deletes child service", %{conn: conn, parent: parent, child: child} do
      {:ok, show_live, _html} = live(conn, ~p"/services/#{parent}")

      assert show_live |> element("#services-#{child.id} a", "Delete") |> render_click()
      refute has_element?(show_live, "#services-#{child.id}")
    end

    test "updates parent service", %{conn: conn, parent: parent} do
      {:ok, _show_live, _html} = live(conn, ~p"/services/#{parent}")

      # Navigate to edit page
      {:ok, edit_live, _html} = live(conn, ~p"/services/#{parent}/edit")
      assert render(edit_live) =~ "Edit Service"

      # Submit the update form
      edit_live
        |> form("#service-form", service: @update_attrs)
        |> render_submit()

      # Wait briefly for the update to be applied
      Process.sleep(100)

      # Verify changes on parent's show page
      {:ok, _show_live, html} = live(conn, ~p"/services/#{parent}")

      # Get the updated parent from the database to ensure it matches
      updated_parent = Services.get_service!(parent.id)
      assert html =~ updated_parent.name
      assert updated_parent.name == @update_attrs.name
    end

    test "handles pub/sub service updates", %{conn: conn, parent: parent, child: child} do
      {:ok, show_live, _html} = live(conn, ~p"/services/#{parent}")

      send(show_live.pid, {:service_updated, %{child | name: "updated via pubsub"}})

      html = render(show_live)
      assert html =~ "updated via pubsub"
    end

    test "handles service deletion with redirect", %{conn: conn, parent: parent} do
      {:ok, show_live, _html} = live(conn, ~p"/services/#{parent}")

      send(show_live.pid, {:service_deleted, parent, nil})

      assert_redirect(show_live, ~p"/services")
    end

    test "shows connected consumers count", %{conn: conn, parent: parent} do
      {:ok, show_live, html} = live(conn, ~p"/services/#{parent}")

      assert html =~ "0 consumer connected"

      send(show_live.pid, {:consumers_connected, 2})
      html = render(show_live)
      assert html =~ "2 consumers connected"
    end

    test "handles form assignment for different actions", %{conn: conn, parent: parent, child: child} do
      # Test :new action
      {:ok, _new_live, html} = live(conn, ~p"/services/#{parent}/new")
      assert html =~ "New Service"
      assert html =~ parent.name

      # Test :edit action for child
      {:ok, _edit_child_live, html} = live(conn, ~p"/services/#{parent}/edit/#{child.id}")
      assert html =~ "Edit Service"
      assert html =~ child.name

      # Test :edit action for parent
      {:ok, _edit_parent_live, html} = live(conn, ~p"/services/#{parent}/edit")
      assert html =~ "Edit Service"
      assert html =~ parent.name
    end

    test "updates service with no relation to current view", %{conn: conn, parent: parent} do
      {:ok, show_live, _html} = live(conn, ~p"/services/#{parent}")

      # Create an unrelated service
      unrelated = service_fixture()
      send(show_live.pid, {:service_updated, unrelated})

      # Instead of comparing full HTML, check specific elements haven't changed
      html = render(show_live)
      assert html =~ parent.name
      refute html =~ unrelated.name
    end

    test "handles service creation for unrelated parent", %{conn: conn, parent: parent} do
      {:ok, show_live, _html} = live(conn, ~p"/services/#{parent}")

      # Create a service with different parent
      other_parent = service_fixture()
      other_child = service_fixture(%{parent_id: other_parent.id})

      send(show_live.pid, {:service_created, other_child})

      # Check specific elements instead of full HTML
      html = render(show_live)
      assert html =~ parent.name
      refute html =~ other_child.name
    end

    test "handles service deletion for unrelated service", %{conn: conn, parent: parent} do
      {:ok, show_live, _html} = live(conn, ~p"/services/#{parent}")

      unrelated = service_fixture()
      initial_html = render(show_live)

      send(show_live.pid, {:service_deleted, unrelated, nil})

      # Check specific elements instead of full HTML
      html = render(show_live)
      assert html =~ parent.name
      refute html =~ unrelated.name
      # Verify key structure remains unchanged
      assert Regex.scan(~r/services-\d+/, html) == Regex.scan(~r/services-\d+/, initial_html)
    end
  end
end
