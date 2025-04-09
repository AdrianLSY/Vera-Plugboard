defmodule Vera.Services.ServiceRequestProducer do
  use GenStage

  @entity_max_age System.get_env("PHX_GENSTAGE_ENTITY_MAX_AGE") |> String.to_integer()
  @cleanup_interval System.get_env("PHX_GENSTAGE_CLEANUP_INTERVAL") |> String.to_integer()

  def start_link(initial_payloads \\ []) do
    GenStage.start_link(__MODULE__, initial_payloads, name: __MODULE__)
  end

  def init(payloads) do
    current_time = System.system_time(:millisecond)
    wrapped_payloads = Enum.map(payloads, fn msg -> {current_time, msg} end)
    schedule_cleanup()
    {:producer, {wrapped_payloads, 0}}
  end

  def enqueue(payload) do
    if Vera.Services.ServiceRegistry.list_clients(payload.service_id) != [] do
      GenStage.cast(__MODULE__, {:enqueue, payload})
      {:ok, "Message enqueued"}
    else
      {:error, "No clients available to handle the request"}
    end
  end

  def handle_demand(incoming_demand, {payloads, pending_demand}) do
    current_time = System.system_time(:millisecond)
    valid_payloads = Enum.filter(payloads, fn {timestamp, _msg} ->
      current_time - timestamp <= @entity_max_age
    end)
    new_demand = incoming_demand + pending_demand
    {to_dispatch, remaining} = Enum.split(valid_payloads, new_demand)
    dispatched_payloads = Enum.map(to_dispatch, fn {_, msg} -> msg end)
    {:noreply, dispatched_payloads, {remaining, new_demand - length(to_dispatch)}}
  end

  def handle_cast({:enqueue, payload}, {payloads, 0}) do
    timestamped = {System.system_time(:millisecond), payload}
    {:noreply, [], {payloads ++ [timestamped], 0}}
  end

  def handle_cast({:enqueue, payload}, {payloads, demand}) do
    {:noreply, [payload], {payloads, demand - 1}}
  end

  def handle_info(:cleanup, {payloads, pending_demand}) do
    schedule_cleanup()
    current_time = System.system_time(:millisecond)

    filtered_payloads = payloads
    |> Enum.filter(fn {timestamp, _msg} ->
      current_time - timestamp <= @entity_max_age
    end)

    {:noreply, [], {filtered_payloads, pending_demand}}
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end
end
