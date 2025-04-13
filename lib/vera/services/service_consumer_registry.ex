defmodule Vera.Services.ServiceConsumerRegistry do
  use GenServer

  def start_link(_args) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def register(service_id, pid) do
    Process.monitor(pid)
    GenServer.call(__MODULE__, {:register, service_id |> to_string(), pid})
    Phoenix.PubSub.broadcast(Vera.PubSub, "service/#{service_id}", {:consumers_connected, list_consumers(service_id) |> length()})
  end

  def unregister(service_id, pid) do
    GenServer.call(__MODULE__, {:unregister, service_id |> to_string(), pid})
    Phoenix.PubSub.broadcast(Vera.PubSub, "service/#{service_id}", {:consumers_connected, list_consumers(service_id) |> length()})
  end

  def get_consumer(service_id) do
    GenServer.call(__MODULE__, {:get_consumer, service_id |> to_string()})
  end

  def list_consumers(service_id) do
    GenServer.call(__MODULE__, {:list_consumers, service_id |> to_string()})
  end

  ## Server Callbacks

  def init(state) do
    {:ok, state}
  end

  def handle_call({:register, service_id, pid}, _from, state) do
    consumers = Map.get(state, service_id, [])
    new_state = Map.put(state, service_id, consumers ++ [pid])
    {:reply, :ok, new_state}
  end

  def handle_call({:unregister, service_id, pid}, _from, state) do
    consumers = Map.get(state, service_id, [])
    new_consumers = List.delete(consumers, pid)
    new_state = Map.put(state, service_id, new_consumers)
    {:reply, :ok, new_state}
  end

  def handle_call({:get_consumer, service_id}, _from, state) do
    consumers = Map.get(state, service_id, [])
    case consumers do
      [] ->
        {:reply, nil, state}
      [first | rest] ->
        new_consumers = rest ++ [first]
        new_state = Map.put(state, service_id, new_consumers)
        {:reply, first, new_state}
    end
  end

  def handle_call({:list_consumers, service_id}, _from, state) do
    consumers = Map.get(state, service_id, [])
    {:reply, consumers, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    new_state = Enum.reduce(state, %{}, fn {service_id, consumers}, acc ->
      updated_consumers = List.delete(consumers, pid)
      Phoenix.PubSub.broadcast(Vera.PubSub, "service/#{service_id}", {:consumers_connected, length(updated_consumers)})
      Map.put(acc, service_id, updated_consumers)
    end)
    {:noreply, new_state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end
end
