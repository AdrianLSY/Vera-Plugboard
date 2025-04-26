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
    {:via, Registry, {Plugboard.Services.ServiceConsumerRegistry, {__MODULE__, to_string(service_id)}}}
  end

  @doc false
  def init(%{service_id: service_id}) do
    producer = Plugboard.Services.ServiceRequestProducer.via_tuple(service_id)

    # Subscribe to the producer with a max_demand of 10
    # This prevents the consumer from overwhelming the system with too many requests at once
    {:consumer, %{service_id: service_id}, subscribe_to: [{producer, max_demand: 10}]}
  end

  @doc false
  def handle_events(events, _from, state) do
    service_id = state.service_id

    Enum.each(events, fn event ->
      # Get the next available consumer using round-robin
      consumer = ServiceConsumerRegistry.cycle_consumers(service_id)

      if consumer do
        # Ensure event has the expected structure
        request = case event do
          %{action: _, fields: _, response_ref: _} = structured_event ->
            # Event already has the right structure
            %{
              action: structured_event.action,
              fields: structured_event.fields,
              response_ref: structured_event.response_ref
            }

          # Handle case where event might be a map without the exact keys
          event when is_map(event) ->
            %{
              action: Map.get(event, :action) || Map.get(event, "action"),
              fields: Map.get(event, :fields) || Map.get(event, "fields") || %{},
              response_ref: Map.get(event, :response_ref) || Map.get(event, "response_ref")
            }

          # Handle case where event is not a map at all
          _ ->
            %{action: "process", fields: %{data: event}, response_ref: nil}
        end

        send(consumer, {:request, request})
      end
    end)

    {:noreply, [], state}
  end
end
