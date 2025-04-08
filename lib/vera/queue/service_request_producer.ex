defmodule Vera.Queue.ServiceRequestProducer do
  use GenStage

  @ttl 30000

  def start_link(initial_payloads \\ []) do
    GenStage.start_link(__MODULE__, initial_payloads, name: __MODULE__)
  end

  def init(payloads) do
    current_time = System.monotonic_time(:millisecond)
    wrapped_payloads = Enum.map(payloads, fn msg -> {current_time, msg} end)
    Process.send_after(self(), :cleanup, 1000)
    {:producer, {wrapped_payloads, 0}}
  end

  def enqueue(payload) do
    if Vera.Registry.ServiceRegistry.list_clients(payload.service_id) != [] do
      GenStage.cast(__MODULE__, {:enqueue, payload})
      {:ok, "Message enqueued"}
    else
      {:error, "No clients available to handle the request"}
    end
  end

  def handle_demand(incoming_demand, {payloads, pending_demand}) do
    now = System.monotonic_time(:millisecond)
    valid_payloads = Enum.filter(payloads, fn {timestamp, _msg} ->
      now - timestamp <= @ttl
    end)
    new_demand = incoming_demand + pending_demand
    {to_dispatch, remaining} = Enum.split(valid_payloads, new_demand)
    dispatched_payloads = Enum.map(to_dispatch, fn {_, msg} -> msg end)
    {:noreply, dispatched_payloads, {remaining, new_demand - length(to_dispatch)}}
  end

  def handle_cast({:enqueue, payload}, {payloads, 0}) do
    timestamped = {System.monotonic_time(:millisecond), payload}
    {:noreply, [], {payloads ++ [timestamped], 0}}
  end

  def handle_cast({:enqueue, payload}, {payloads, demand}) do
    {:noreply, [payload], {payloads, demand - 1}}
  end

  def handle_info(:cleanup, {payloads, pending_demand}) do
    now = System.monotonic_time(:millisecond)
    filtered_payloads = Enum.filter(payloads, fn {timestamp, _msg} ->
      now - timestamp <= @ttl
    end)
    Process.send_after(self(), :cleanup, 1000)
    {:noreply, [], {filtered_payloads, pending_demand}}
  end
end
