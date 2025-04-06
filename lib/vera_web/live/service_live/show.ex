defmodule VeraWeb.ServiceLive.Show do
  use VeraWeb, :live_view

  alias Vera.Services
  alias Vera.Services.Service

  @impl true
  def mount(params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Vera.PubSub, "service/#{params["id"]}")
    end
    {:ok, stream(socket, :services, [])}
  end

  @impl true
  def handle_params(%{"id" => id} = params, _, socket) do
    service = Services.get_service!(id) |> Vera.Repo.preload([:parent, :children])
    childrens = service.children |> Vera.Repo.preload([:parent])
    full_path = Service.full_path(service)
    clients_connected = Vera.Queue.Registry.list_clients(service.id |> to_string()) |> length()
    socket = socket
      |> assign(:service, service)
      |> assign(:services, childrens)
      |> assign(:full_path, full_path)
      |> assign(:clients_connected, clients_connected)
      |> assign(:page_title, page_title(socket.assigns.live_action))
      |> assign_form_service(socket.assigns.live_action, params)

    {:noreply, socket}
  end

  defp assign_form_service(socket, :new, _params) do
    assign(socket, :form_service, %Service{parent_id: socket.assigns.service.id})
  end

  defp assign_form_service(socket, :edit, %{"child_id" => child_id}) do
    service = Services.get_service!(child_id)
    assign(socket, :form_service, service)
  end

  defp assign_form_service(socket, :edit, %{"id" => id}) do
    service = Services.get_service!(id)
    assign(socket, :form_service, service)
  end

  defp assign_form_service(socket, _action, _params), do: socket

  @impl true
  def handle_info({VeraWeb.ServiceLive.FormComponent, {:saved, service}}, socket) do
    service = Vera.Repo.preload(service, [:parent])
    {:noreply, stream_insert(socket, :services, service)}
  end

  @impl true
  def handle_info({:service_created, service}, socket) do
    service = Vera.Repo.preload(service, [:parent])
    if service.parent_id == socket.assigns.service.id do
      {:noreply,
        socket
        |> put_flash(:info, "Child service created")
        |> stream_insert(:services, service)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:service_updated, service}, socket) do
    service = Vera.Repo.preload(service, [:parent])
    cond do
      service.id == socket.assigns.service.id ->
        {:noreply,
          socket
          |> assign(:service, service)}
      service.parent_id == socket.assigns.service.id ->
        {:noreply,
          socket
          |> put_flash(:info, "Child service updated")
          |> stream_insert(:services, service)}
      true ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:service_deleted, service, redirect_service_id}, socket) do
    service = Vera.Repo.preload(service, [:parent])
    cond do
      service.id == socket.assigns.service.id ->
        {:noreply,
          socket
          |> push_navigate(to: (if redirect_service_id, do: ~p"/services/#{redirect_service_id}", else: ~p"/services"))}
      service.parent_id == socket.assigns.service.id ->
        {:noreply,
          socket
          |> put_flash(:info, "Child service deleted")
          |> stream_delete(:services, service)}
      true ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:path_updated, full_path}, socket) do
    {:noreply,
      socket
      |> put_flash(:info, "Service path updated")
      |> assign(:full_path, full_path)}
  end

  @impl true
  def handle_info({:clients_connected, clients_connected}, socket) do
    {:noreply, assign(socket, :clients_connected, clients_connected)}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    service = Services.get_service!(id)
    {:ok, _} = Services.delete_service(service)

    {:noreply, stream_delete(socket, :services, service)}
  end

  defp page_title(:new), do: "New Service"
  defp page_title(:show), do: "Plugboard Service"
  defp page_title(:edit), do: "Edit Service"
  defp page_title(:delete), do: "Delete Service"
end
