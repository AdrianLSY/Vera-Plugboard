defmodule VeraWeb.ServiceBackend do
  use Phoenix.Channel

  # Join the channel with a topic like "service_api:123"
  def join("service/" <> service_id, _params, socket) do
    # Subscribe to the PubSub topic to receive external events
    :ok = Phoenix.PubSub.subscribe(Vera.PubSub, "service/#{service_id}/backend")
    {:ok, assign(socket, :service_id, service_id)}
  end

  # Handle incoming events from the client if needed
  def handle_in("some_event", payload, socket) do
    # Optionally broadcast or process the message
    broadcast!(socket, "some_event", payload)
    {:noreply, socket}
  end

  # Handle messages sent from PubSub to this channel
  def handle_info(message, socket) do
    push(socket, "new_message", message)
    {:noreply, socket}
  end
end
