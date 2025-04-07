defmodule Vera.Queue.ServiceRequestProducer do
  use GenStage

  def start_link(initial_messages \\ []) do
    GenStage.start_link(__MODULE__, initial_messages, name: __MODULE__)
  end

  def init(messages) do
    {:producer, {messages, 0}}
  end

  def handle_demand(incoming_demand, {messages, pending_demand}) do
    new_demand = incoming_demand + pending_demand
    {to_dispatch, remaining} = Enum.split(messages, new_demand)
    {:noreply, to_dispatch, {remaining, new_demand - length(to_dispatch)}}
  end

  def enqueue(message) do
    if Vera.Registry.ServiceRegistry.list_clients(message.service_id) != [] do
      GenStage.cast(__MODULE__, {:enqueue, message})
      {:ok, "Message enqueued"}
    else
      {:error, "No clients available to handle the request"}
    end
  end

  def handle_cast({:enqueue, message}, {messages, 0}) do
    {:noreply, [], {messages ++ [message], 0}}
  end

  def handle_cast({:enqueue, message}, {messages, demand}) do
    {:noreply, [message], {messages, demand - 1}}
  end
end
