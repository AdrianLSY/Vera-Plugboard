defmodule Vera.Queue.ServiceRequestProducer do
  use GenStage

  @ttl 30000

  def start_link(initial_messages \\ []) do
    GenStage.start_link(__MODULE__, initial_messages, name: __MODULE__)
  end

  def init(messages) do
    current_time = System.monotonic_time(:millisecond)
    wrapped_messages = Enum.map(messages, fn msg -> {current_time, msg} end)
    Process.send_after(self(), :cleanup, 1000)
    {:producer, {wrapped_messages, 0}}
  end

  def enqueue(message) do
    if Vera.Registry.ServiceRegistry.list_clients(message.service_id) != [] do
      GenStage.cast(__MODULE__, {:enqueue, message})
      {:ok, "Message enqueued"}
    else
      {:error, "No clients available to handle the request"}
    end
  end

  def handle_demand(incoming_demand, {messages, pending_demand}) do
    now = System.monotonic_time(:millisecond)
    valid_messages = Enum.filter(messages, fn {timestamp, _msg} ->
      now - timestamp <= @ttl
    end)
    new_demand = incoming_demand + pending_demand
    {to_dispatch, remaining} = Enum.split(valid_messages, new_demand)
    dispatched_messages = Enum.map(to_dispatch, fn {_, msg} -> msg end)
    {:noreply, dispatched_messages, {remaining, new_demand - length(to_dispatch)}}
  end

  def handle_cast({:enqueue, message}, {messages, 0}) do
    timestamped = {System.monotonic_time(:millisecond), message}
    {:noreply, [], {messages ++ [timestamped], 0}}
  end

  def handle_cast({:enqueue, message}, {messages, demand}) do
    {:noreply, [message], {messages, demand - 1}}
  end

  def handle_info(:cleanup, {messages, pending_demand}) do
    now = System.monotonic_time(:millisecond)
    filtered_messages = Enum.filter(messages, fn {timestamp, _msg} ->
      now - timestamp <= @ttl
    end)
    Process.send_after(self(), :cleanup, 1000)
    {:noreply, [], {filtered_messages, pending_demand}}
  end
end
