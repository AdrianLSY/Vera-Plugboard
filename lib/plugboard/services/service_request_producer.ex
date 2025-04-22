defmodule Plugboard.Services.ServiceRequestProducer do
  use GenStage
  alias Plugboard.Services.ServiceConsumerRegistry

  @entity_max_age System.get_env("PHX_GENSTAGE_ENTITY_MAX_AGE") |> String.to_integer()
  @cleanup_interval System.get_env("PHX_GENSTAGE_CLEANUP_INTERVAL") |> String.to_integer()

  def start_link(initial_requests \\ []) do
    GenStage.start_link(__MODULE__, initial_requests, name: __MODULE__)
  end

  def init(requests) do
    current_time = System.system_time(:millisecond)
    wrapped_requests = Enum.map(requests, fn msg -> {current_time, msg} end)
    schedule_cleanup()
    {:producer, {wrapped_requests, 0}}
  end

  def enqueue(request) do
    if ServiceConsumerRegistry.consumers(request.service_id) != [] do
      GenStage.cast(__MODULE__, {:enqueue, request})
      {:ok, "Message enqueued"}
    else
      {:error, "No service consumers are available to handle the request"}
    end
  end

  def handle_demand(incoming_demand, {requests, pending_demand}) do
    current_time = System.system_time(:millisecond)
    valid_requests = Enum.filter(requests, fn {timestamp, _msg} ->
      current_time - timestamp <= @entity_max_age
    end)
    new_demand = incoming_demand + pending_demand
    {to_dispatch, remaining} = Enum.split(valid_requests, new_demand)
    dispatched_requests = Enum.map(to_dispatch, fn {_, msg} -> msg end)
    {:noreply, dispatched_requests, {remaining, new_demand - length(to_dispatch)}}
  end

  def handle_cast({:enqueue, request}, {requests, 0}) do
    timestamped = {System.system_time(:millisecond), request}
    {:noreply, [], {requests ++ [timestamped], 0}}
  end

  def handle_cast({:enqueue, request}, {requests, demand}) do
    {:noreply, [request], {requests, demand - 1}}
  end

  def handle_info(:cleanup, {requests, pending_demand}) do
    schedule_cleanup()
    current_time = System.system_time(:millisecond)

    filtered_requests = requests
    |> Enum.filter(fn {timestamp, _msg} ->
      current_time - timestamp <= @entity_max_age
    end)

    {:noreply, [], {filtered_requests, pending_demand}}
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end
end
