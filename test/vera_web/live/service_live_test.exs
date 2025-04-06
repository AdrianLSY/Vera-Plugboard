defmodule VeraWeb.ServiceLiveTest do
  use VeraWeb.ConnCase

  import Phoenix.LiveViewTest
  import Vera.ServicesFixtures

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
      html = edit_live
             |> form("#service-form", service: @update_attrs)
             |> render_submit()

      # Wait briefly for the update to be applied
      Process.sleep(100)

      # Verify changes on parent's show page
      {:ok, _show_live, html} = live(conn, ~p"/services/#{parent}")

      # Get the updated parent from the database to ensure it matches
      updated_parent = Vera.Services.get_service!(parent.id)
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

    test "shows connected clients count", %{conn: conn, parent: parent} do
      {:ok, show_live, html} = live(conn, ~p"/services/#{parent}")

      assert html =~ "0 client connected"

      send(show_live.pid, {:clients_connected, 2})
      html = render(show_live)
      assert html =~ "2 clients connected"
    end
  end
end
