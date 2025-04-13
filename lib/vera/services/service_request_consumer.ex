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
    consumer = Vera.Services.ServiceConsumerRegistry.get_consumer(service_id)
    if consumer do
      send(consumer, {:request, %{action: event.action, fields: event.fields, response_ref: event.response_ref}})
    end
  end)
  {:noreply, [], state}
end
end
