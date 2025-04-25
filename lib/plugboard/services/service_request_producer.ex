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
    schedule_cleanup()
    {:producer, {[], 0, service_id}}
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
  def handle_demand(incoming_demand, {requests, pending_demand, service_id}) do
    current_time = System.system_time(:millisecond)
    valid_requests = Enum.filter(requests, fn {timestamp, _msg} ->
      current_time - timestamp <= @entity_max_age
    end)
    new_demand = incoming_demand + pending_demand
    {to_dispatch, remaining} = Enum.split(valid_requests, new_demand)
    dispatched_requests = Enum.map(to_dispatch, fn {_, msg} -> msg end)
    {:noreply, dispatched_requests, {remaining, new_demand - length(to_dispatch), service_id}}
  end

  @doc false
  def handle_cast({:enqueue, request}, {requests, 0, service_id}) do
    timestamped = {System.system_time(:millisecond), request}
    {:noreply, [], {requests ++ [timestamped], 0, service_id}}
  end

  @doc false
  def handle_cast({:enqueue, request}, {requests, demand, service_id}) do
    {:noreply, [request], {requests, demand - 1, service_id}}
  end

  @doc false
  def handle_info(:cleanup, {requests, pending_demand, service_id}) do
    schedule_cleanup()
    current_time = System.system_time(:millisecond)

    filtered_requests = requests
    |> Enum.filter(fn {timestamp, _msg} ->
      current_time - timestamp <= @entity_max_age
    end)

    {:noreply, [], {filtered_requests, pending_demand, service_id}}
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end
end
