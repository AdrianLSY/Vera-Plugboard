defmodule VeraWeb.ServiceBackend do
  use Phoenix.Channel

  alias Vera.Services.Service
  alias Vera.Repo

  def join("backend/service/" <> service_id, _params, socket) do
    case Service.default_scope()
    |> Repo.get(service_id) do
      nil ->
        {:error, %{reason: "Service not found"}}
      service ->
        :ok = Phoenix.PubSub.subscribe(Vera.PubSub, "service/#{service_id}")
        {:ok, %{service: service}, assign(socket, :service_id, service_id)}
    end
  end

  def handle_info({:service_updated, service}, socket) do
    broadcast!(socket, "service_updated", %{service: service})
    {:noreply, socket}
  end

  def handle_info({:service_deleted, service, _redirect_service_id}, socket) do
    broadcast!(socket, "service_deleted", %{service: service})
    {:noreply, socket}
  end

  # Ignore all other messages
  def handle_info(_msg, socket), do: {:noreply, socket}
end
