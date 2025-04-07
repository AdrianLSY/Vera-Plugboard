defmodule VeraWeb.BackendChannel do
  use Phoenix.Channel

  alias Vera.Services.Service
  alias Vera.Repo

  @impl true
  def join("backend/service/" <> service_id, _payload, socket) do
    case Service.default_scope()
    |> Repo.get(service_id) do
      nil ->
        {:error, %{reason: "Service not found"}}
      service ->
        Vera.Registry.ServiceRegistry.register(service_id, self())
        Phoenix.PubSub.subscribe(Vera.PubSub, "service/#{service_id}")
        {:ok, %{service: service, clients_connected: Vera.Registry.ServiceRegistry.list_clients(service.id) |> length()}, assign(socket, :service_id, service_id)}
    end
  end

  @impl true
  def terminate(_reason, socket) do
    service_id = socket.assigns[:service_id]
    Vera.Registry.ServiceRegistry.unregister(service_id, self())
    :ok
  end

  @impl true
  def handle_info({:request, message}, socket) do
    push(socket, "request", message)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:service_updated, service}, socket) do
    push(socket, "service_updated", %{service: service})
    {:noreply, socket}
  end

  @impl true
  def handle_info({:service_deleted, service, _redirect_service_id}, socket) do
    push(socket, "service_deleted", %{service: service})
    {:noreply, socket}
  end

  @impl true
  def handle_info({:path_updated, full_path}, socket) when is_list(full_path) do
    {:noreply, socket}
  end

  @impl true
  def handle_info({:clients_connected, clients_connected}, socket) do
    push(socket, "clients_connected", %{clients_connected: clients_connected})
    {:noreply, socket}
  end
end
