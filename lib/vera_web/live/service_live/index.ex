defmodule VeraWeb.ServiceLive.Index do
  use VeraWeb, :live_view

  alias Vera.Services
  alias Vera.Services.Service

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Vera.PubSub, "services")
    {:ok, stream(socket, :services, Services.list_services())}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    socket
    |> assign(:page_title, "Edit Service")
    |> assign(:service, Services.get_service!(id))
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New Service")
    |> assign(:service, %Service{})
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Listing Services")
    |> assign(:service, nil)
  end

  @impl true
  def handle_info({VeraWeb.ServiceLive.FormComponent, {:saved, service}}, socket) do
    {:noreply, stream_insert(socket, :services, service)}
  end

  @impl true
  def handle_info({:service_created, service}, socket) do
    {:noreply, stream_insert(socket, :services, service)}
  end

  @impl true
  def handle_info({:service_updated, service}, socket) do
    {:noreply, stream_insert(socket, :services, service)}
  end

  @impl true
  def handle_info({:service_deleted, service}, socket) do
    {:noreply, stream_delete(socket, :services, service)}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    service = Services.get_service!(id)
    {:ok, _} = Services.delete_service(service)

    {:noreply, stream_delete(socket, :services, service)}
  end
end
