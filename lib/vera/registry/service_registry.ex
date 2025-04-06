defmodule Vera.Registry.ServiceRegistry do
  use GenServer

  ## Client API

  def start_link(_args) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def register(service_id, pid) do
    Process.monitor(pid)
    GenServer.call(__MODULE__, {:register, service_id |> to_string(), pid})
    Phoenix.PubSub.broadcast(Vera.PubSub, "service/#{service_id}", {:clients_connected, list_clients(service_id) |> length()})
  end

  def unregister(service_id, pid) do
    GenServer.call(__MODULE__, {:unregister, service_id |> to_string(), pid})
    Phoenix.PubSub.broadcast(Vera.PubSub, "service/#{service_id}", {:clients_connected, list_clients(service_id) |> length()})
  end

  def get_client(service_id) do
    GenServer.call(__MODULE__, {:get_client, service_id |> to_string()})
  end

  def list_clients(service_id) do
    GenServer.call(__MODULE__, {:list_clients, service_id |> to_string()})
  end

  ## Server Callbacks

  def init(state) do
    {:ok, state}
  end

  def handle_call({:register, service_id, pid}, _from, state) do
    clients = Map.get(state, service_id, [])
    new_state = Map.put(state, service_id, clients ++ [pid])
    {:reply, :ok, new_state}
  end

  def handle_call({:unregister, service_id, pid}, _from, state) do
    clients = Map.get(state, service_id, [])
    new_clients = List.delete(clients, pid)
    new_state = Map.put(state, service_id, new_clients)
    {:reply, :ok, new_state}
  end

  def handle_call({:get_client, service_id}, _from, state) do
    clients = Map.get(state, service_id, [])
    client = List.first(clients)
    {:reply, client, state}
  end

  def handle_call({:list_clients, service_id}, _from, state) do
    clients = Map.get(state, service_id, [])
    {:reply, clients, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    new_state = Enum.reduce(state, %{}, fn {service_id, clients}, acc ->
      updated_clients = List.delete(clients, pid)
      Phoenix.PubSub.broadcast(Vera.PubSub, "service/#{service_id}", {:clients_connected, length(updated_clients)})
      Map.put(acc, service_id, updated_clients)
    end)
    {:noreply, new_state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end
end
