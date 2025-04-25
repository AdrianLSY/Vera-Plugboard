defmodule Plugboard.Services.ServiceRequestConsumer do
  use GenStage
  alias Plugboard.Services.ServiceConsumerRegistry

  @doc false
  def start_link(opts) do
    service_id = Keyword.fetch!(opts, :service_id)
    name = via_tuple(service_id)
    GenStage.start_link(__MODULE__, %{service_id: service_id}, name: name)
  end

  @doc """
  Creates a unique name for the GenServer based on the service_id
  """
  def via_tuple(service_id) do
    {:via, Registry, {Plugboard.Services.ServiceRegistry, {__MODULE__, to_string(service_id)}}}
  end

  @doc false
  def init(%{service_id: service_id}) do
    producer = Plugboard.Services.ServiceRequestProducer.via_tuple(service_id)
    {:consumer, %{service_id: service_id}, subscribe_to: [{producer, []}]}
  end

  @doc false
  def handle_events(events, _from, state) do
    service_id = state.service_id
    Enum.each(events, fn event ->
      consumer = ServiceConsumerRegistry.cycle(service_id)
      if consumer do
        send(consumer, {:request, %{action: event.action, fields: event.fields, response_ref: event.response_ref}})
      end
    end)
    {:noreply, [], state}
  end
end
