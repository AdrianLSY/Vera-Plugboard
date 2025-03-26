defmodule VeraWeb.ServiceLiveTest do
  use VeraWeb.ConnCase

  import Phoenix.LiveViewTest
  import Vera.ServicesFixtures

  @create_attrs %{name: "some name"}
  @update_attrs %{name: "some updated name"}
  @invalid_attrs %{name: nil}

  defp create_service(_) do
    service = service_fixture()
    %{service: service}
  end

  describe "Index" do
    setup [:create_service]

    test "lists all services", %{conn: conn, service: service} do
      {:ok, _index_live, html} = live(conn, ~p"/services")

      assert html =~ "Listing Services"
      assert html =~ service.name
    end

    test "saves new service", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/services")

      assert index_live |> element("a", "New Service") |> render_click() =~
               "New Service"

      assert_patch(index_live, ~p"/services/new")

      assert index_live
             |> form("#service-form", service: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      assert index_live
             |> form("#service-form", service: @create_attrs)
             |> render_submit()

      assert_patch(index_live, ~p"/services")

      html = render(index_live)
      assert html =~ "Service created successfully"
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

      assert index_live
             |> form("#service-form", service: @update_attrs)
             |> render_submit()

      assert_patch(index_live, ~p"/services")

      html = render(index_live)
      assert html =~ "Service updated successfully"
      assert html =~ "some updated name"
    end

    test "deletes service in listing", %{conn: conn, service: service} do
      {:ok, index_live, _html} = live(conn, ~p"/services")

      assert index_live |> element("#services-#{service.id} a", "Delete") |> render_click()
      refute has_element?(index_live, "#services-#{service.id}")
    end
  end

  describe "Show" do
    setup [:create_service]

    test "displays service", %{conn: conn, service: service} do
      {:ok, _show_live, html} = live(conn, ~p"/services/#{service}")

      assert html =~ "Show Service"
      assert html =~ service.name
    end

    test "updates service within modal", %{conn: conn, service: service} do
      {:ok, show_live, _html} = live(conn, ~p"/services/#{service}")

      assert show_live |> element("a", "Edit") |> render_click() =~
               "Edit Service"

      assert_patch(show_live, ~p"/services/#{service}/show/edit")

      assert show_live
             |> form("#service-form", service: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      assert show_live
             |> form("#service-form", service: @update_attrs)
             |> render_submit()

      assert_patch(show_live, ~p"/services/#{service}")

      html = render(show_live)
      assert html =~ "Service updated successfully"
      assert html =~ "some updated name"
    end
  end
end
