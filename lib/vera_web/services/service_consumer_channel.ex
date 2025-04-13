defmodule VeraWeb.Services.ServiceConsumerChannel do
  use Phoenix.Channel

  alias Vera.Services.Service
  alias Vera.Repo

  def join("service/" <> service_id, _payload, socket) do
    case Service.default_scope()
    |> Repo.get(service_id) do
      nil ->
        {:error, %{reason: "Service not found"}}
      service ->
        Vera.Services.ServiceConsumerRegistry.register(service_id, self())
        Phoenix.PubSub.subscribe(Vera.PubSub, "service/#{service_id}")
        {:ok, %{service: service, consumers_connected: Vera.Services.ServiceConsumerRegistry.list_consumers(service.id) |> length()}, assign(socket, :service_id, service_id)}
    end
  end

  def terminate(_reason, socket) do
    service_id = socket.assigns[:service_id]
    Vera.Services.ServiceConsumerRegistry.unregister(service_id, self())
    :ok
  end

  def handle_in("response", payload, socket) do
    if pid = Vera.Services.ServiceRequestRegistry.get_requester(socket.ref) do
      send(pid, {:response, payload})
    end
    {:noreply, socket}
  end

  def handle_info({:request, payload}, socket) do
    push(socket, "request", payload)
    {:noreply, socket}
  end

  def handle_info({:service_updated, service}, socket) do
    push(socket, "service_updated", %{service: service})
    {:noreply, socket}
  end

  def handle_info({:service_deleted, service, _redirect_service_id}, socket) do
    push(socket, "service_deleted", %{service: service})
    {:noreply, socket}
  end

  def handle_info({:path_updated, full_path}, socket) when is_list(full_path) do
    {:noreply, socket}
  end

  def handle_info({:consumers_connected, consumers_connected}, socket) do
    push(socket, "consumers_connected", %{consumers_connected: consumers_connected})
    {:noreply, socket}
  end
end
