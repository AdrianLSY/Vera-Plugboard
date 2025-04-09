defmodule Vera.Services.ServiceRequestConsumer do
  use GenStage

  def start_link(_args) do
    GenStage.start_link(__MODULE__, :ok)
  end

  def init(:ok) do
    {:consumer, :ok, subscribe_to: [Vera.Services.ServiceRequestProducer]}
  end

  def handle_events(events, _from, state) do
  Enum.each(events, fn event ->
    service_id = event.service_id
    client = Vera.Services.ServiceRegistry.get_client(service_id)
    if client do
      send(client, {:request, %{response_ref: event.response_ref, body: event.payload}})
    end
  end)
  {:noreply, [], state}
end
end
