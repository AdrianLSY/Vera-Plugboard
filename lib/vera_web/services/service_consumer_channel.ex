defmodule VeraWeb.Services.ServiceConsumerChannel do
  use Phoenix.Channel
  alias Vera.Services.Services
  alias Vera.Services.ServiceActionRegistry
  alias Vera.Services.ServiceRequestRegistry
  alias Vera.Services.ServiceConsumerRegistry

  @service_token_validity_in_days System.get_env("PHX_SERVICE_TOKEN_VALIDITY_IN_DAYS") |> String.to_integer()

  def join("service/" <> service_id, %{"token" => token, "actions" => actions}, socket) do
    with {:ok, service} <- Services.fetch_service_by_api_token(token) do

      token_response = %{
        id: service.token.id,
        context: service.token.context,
        service_id: service.id,
        inserted_at: token.inserted_at,
        expires_at: DateTime.add(token.inserted_at, @service_token_validity_in_days * 24 * 60 * 60, :second)
      }

      if ServiceConsumerRegistry.list_consumers(service_id) |> length() > 0 do
        registered_actions = ServiceActionRegistry.get_actions(service_id)
        if actions != registered_actions do
          {:error, %{reason: "Current consumer actions do not match other registered consumer actions"}}
        else
          ServiceConsumerRegistry.register(service_id, self())
          {:ok, %{service: service, token: token_response, consumers_connected: ServiceConsumerRegistry.list_consumers(service.id) |> length()}, assign(socket, :service_id, service_id)}
        end
      else
        ServiceConsumerRegistry.register(service_id, self())
        ServiceActionRegistry.register(service_id, actions)
        {:ok, %{service: service, token: token_response, consumers_connected: ServiceConsumerRegistry.list_consumers(service.id) |> length()}, assign(socket, :service_id, service_id)}
      end
    else
      :error -> {:error, %{reason: "Service API token is invalid"}}
      nil -> {:error, %{reason: "Service API token is invalid"}}
    end
  end

  def terminate(_reason, socket) do
    service_id = socket.assigns[:service_id]
    ServiceConsumerRegistry.unregister(service_id, self())
    if ServiceConsumerRegistry.list_consumers(service_id) |> length() == 0 do
      ServiceActionRegistry.unregister(service_id)
    end
    :ok
  end

  def handle_in("response", payload, socket) do
    if pid = ServiceRequestRegistry.get_requester(socket.ref) do
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

  def handle_info({:token_created, token, token}, socket) do
    token_response = %{
      id: token.id,
      value: token,
      context: token.context,
      service_id: token.service_id,
      inserted_at: token.inserted_at,
      expires_at: DateTime.add(token.inserted_at, @service_token_validity_in_days * 24 * 60 * 60, :second)
    }
    push(socket, "token_created", %{token: token_response})
    {:noreply, socket}
  end

  def handle_info({:token_deleted, token}, socket) do
    token_response = %{
      id: token.id,
      context: token.context,
      service_id: token.service_id,
      inserted_at: token.inserted_at,
      expires_at: DateTime.add(token.inserted_at, @service_token_validity_in_days * 24 * 60 * 60, :second)
    }
    push(socket, "token_deleted", %{token: token_response})
    {:noreply, socket}
  end
end
