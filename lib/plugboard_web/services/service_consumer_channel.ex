defmodule PlugboardWeb.Services.ServiceConsumerChannel do
  use Phoenix.Channel
  alias Phoenix.PubSub
  alias Plugboard.Services.ServiceConsumerRegistry

  @service_token_validity_in_days System.get_env("PHX_SERVICE_TOKEN_VALIDITY_IN_DAYS")
                                  |> String.to_integer()

  def join("service", _params, socket) do
    service = socket.assigns.service
    token = socket.assigns.token
    actions = socket.assigns.actions
    service_id = socket.assigns.service_id

    ServiceConsumerRegistry.register_consumer(service_id, self())

    if ServiceConsumerRegistry.num_consumers(service_id) == 1 do
      ServiceConsumerRegistry.register_actions(service_id, Jason.decode!(actions))
    end

    # Subscribe to service-specific PubSub topics
    PubSub.subscribe(Plugboard.PubSub, "service/#{service_id}")

    {:ok,
     %{
       service: service,
       token: token,
       num_consumers: ServiceConsumerRegistry.num_consumers(service.id)
     }, socket}
  end

  def terminate(_reason, socket) do
    service_id = socket.assigns[:service_id]
    ServiceConsumerRegistry.unregister_consumer(service_id, self())

    if ServiceConsumerRegistry.num_consumers(service_id) == 0 do
      ServiceConsumerRegistry.unregister_actions(service_id)
    end

    PubSub.unsubscribe(Plugboard.PubSub, "service/#{service_id}")
    :ok
  end

  def handle_in("response", payload, socket) do
    if pid = ServiceConsumerRegistry.get_requester(socket.assigns.service_id, socket.ref) do
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

  def handle_info({:num_consumers, num_consumers}, socket) do
    push(socket, "num_consumers", %{num_consumers: num_consumers})
    {:noreply, socket}
  end

  def handle_info({:actions, _actions}, socket) do
    {:noreply, socket}
  end

  def handle_info({:token_created, token}, socket) do
    token_response = %{
      id: token.id,
      value: token.value,
      context: token.context,
      service_id: token.service_id,
      inserted_at: token.inserted_at,
      expires_at:
        DateTime.add(token.inserted_at, @service_token_validity_in_days * 24 * 60 * 60, :second)
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
      expires_at:
        DateTime.add(token.inserted_at, @service_token_validity_in_days * 24 * 60 * 60, :second)
    }

    push(socket, "token_deleted", %{token: token_response})
    {:noreply, socket}
  end
end
