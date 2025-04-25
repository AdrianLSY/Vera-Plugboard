defmodule Plugboard.Services.ServiceRequestProducer do
  use GenStage
  alias Plugboard.Services.ServiceConsumerRegistry

  @entity_max_age System.get_env("PHX_GENSTAGE_ENTITY_MAX_AGE") |> String.to_integer()
  @cleanup_interval System.get_env("PHX_GENSTAGE_CLEANUP_INTERVAL") |> String.to_integer()

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
    # Create ETS table for this service
    table_name = get_table_name(service_id)
    :ets.new(table_name, [:ordered_set, :protected, :named_table])

    schedule_cleanup()
    {:producer, {0, service_id}}
  end

  defp get_table_name(service_id) do
    :"service_requests_#{service_id}"
  end

  @doc """
  Enqueues a request for a specific service
  """
  def enqueue(service_id, request) do
    if ServiceConsumerRegistry.consumers(service_id) != [] do
      GenStage.cast(via_tuple(service_id), {:enqueue, request})
      {:ok, "Message enqueued"}
    else
      {:error, "No service consumers are available to handle the request"}
    end
  end

  @doc false
  def handle_demand(incoming_demand, {pending_demand, service_id}) do
    table_name = get_table_name(service_id)
    current_time = System.system_time(:millisecond)
    new_demand = incoming_demand + pending_demand

    # Fetch and remove up to new_demand items from ETS
    {dispatched_requests, remaining_demand} =
      :ets.foldl(
        fn {timestamp, msg}, {acc, demand} ->
          if demand > 0 and current_time - timestamp <= @entity_max_age do
            :ets.delete(table_name, timestamp)
            {[msg | acc], demand - 1}
          else
            {acc, demand}
          end
        end,
        {[], new_demand},
        table_name
      )

    {:noreply, Enum.reverse(dispatched_requests), {remaining_demand, service_id}}
  end

  @doc false
  def handle_cast({:enqueue, request}, {0, service_id}) do
    # Store in ETS with timestamp as key
    table_name = get_table_name(service_id)
    timestamp = System.system_time(:millisecond)
    :ets.insert(table_name, {timestamp, request})

    {:noreply, [], {0, service_id}}
  end

  @doc false
  def handle_cast({:enqueue, request}, {demand, service_id}) do
    # Directly dispatch if there's existing demand
    {:noreply, [request], {demand - 1, service_id}}
  end

  @doc false
  def handle_info(:cleanup, {pending_demand, service_id}) do
    schedule_cleanup()
    table_name = get_table_name(service_id)
    current_time = System.system_time(:millisecond)

    # Delete expired entries
    :ets.foldl(
      fn {timestamp, _msg}, _ ->
        if current_time - timestamp > @entity_max_age do
          :ets.delete(table_name, timestamp)
        end
        nil
      end,
      nil,
      table_name
    )

    {:noreply, [], {pending_demand, service_id}}
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end
end
