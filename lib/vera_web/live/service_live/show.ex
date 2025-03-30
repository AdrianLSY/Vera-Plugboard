defmodule VeraWeb.ServiceLive.Show do
  use VeraWeb, :live_view

  alias Vera.Services
  alias Vera.Services.Service

  @impl true
  def mount(params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Vera.PubSub, "service_#{params["id"]}")
    end
    {:ok, stream(socket, :services, [])}
  end

  @impl true
  def handle_params(%{"id" => id} = params, _, socket) do
    service = Services.get_service!(id) |> Vera.Repo.preload([:parent, :children])
    children = service.children |> Vera.Repo.preload([:parent])

    socket = socket
      |> stream(:services, children)
      |> assign(:service, service)
      |> assign(:page_title, page_title(socket.assigns.live_action))
      |> assign_form_service(socket.assigns.live_action, params)

    {:noreply, socket}
  end

  defp assign_form_service(socket, :new, _params) do
    assign(socket, :form_service, %Service{parent_id: socket.assigns.service.id})
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
      {:noreply, stream_insert(socket, :services, service)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:service_updated, service}, socket) do
    service = Vera.Repo.preload(service, [:parent])
    cond do
      service.id == socket.assigns.service.id ->
        {:noreply, assign(socket, :service, service)}
      service.parent_id == socket.assigns.service.id ->
        {:noreply, stream_insert(socket, :services, service)}
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
          |> put_flash(:error, "Service was deleted")
          |> push_navigate(to: (if redirect_service_id, do: ~p"/services/#{redirect_service_id}", else: ~p"/services"))}
      service.parent_id == socket.assigns.service.id ->
        {:noreply, stream_delete(socket, :services, service)}
      true ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    service = Services.get_service!(id)
    {:ok, _} = Services.delete_service(service)

    {:noreply, stream_delete(socket, :services, service)}
  end

  defp page_title(:new), do: "New Service"
  defp page_title(:show), do: "Show Service"
  defp page_title(:edit), do: "Edit Service"
  defp page_title(:delete), do: "Delete Service"
end
