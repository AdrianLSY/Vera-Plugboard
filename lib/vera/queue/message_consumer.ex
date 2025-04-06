defmodule Vera.Queue.MessageConsumer do
  use GenStage

  def start_link(_args) do
    GenStage.start_link(__MODULE__, :ok)
  end

  def init(:ok) do
    # Subscribe to our producer.
    {:consumer, :ok, subscribe_to: [Vera.Queue.MessageProducer]}
  end

  def handle_events(events, _from, state) do
    Enum.each(events, fn event ->
      # Expect each event to be a map with :service_id and :message keys.
      service_id = event.service_id
      client = Vera.Queue.Registry.get_client(service_id)
      if client do
        send(client, {:new_message, event.message})
      else
        IO.puts("No client available for service #{service_id}")
        # Optionally, you could store the event for later or log it.
      end
    end)
    {:noreply, [], state}
  end
end
