defmodule Vera.Services.ServiceActionRegistry do
  use GenServer

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def register(service_id, action) do
    GenServer.cast(__MODULE__, {:register, service_id |> to_string(), action})
    Phoenix.PubSub.broadcast(Vera.PubSub, "service/#{service_id}", {:actions, action})
  end

  def unregister(service_id) do
    GenServer.cast(__MODULE__, {:unregister, service_id |> to_string()})
    Phoenix.PubSub.broadcast(Vera.PubSub, "service/#{service_id}", {:actions, %{}})
  end

  def get_actions(service_id) do
    GenServer.call(__MODULE__, {:get_actions, service_id |> to_string()})
  end

  def init(state) do
    {:ok, state}
  end

  def handle_cast({:register, service_id, action}, state) do
    updated_state = Map.put(state, service_id, action)
    {:noreply, updated_state}
  end

  def handle_cast({:unregister, service_id}, state) do
    {:noreply, Map.delete(state, service_id)}
  end

  def handle_call({:get_actions, service_id}, _from, state) do
    actions = Map.get(state, service_id, %{})
    {:reply, actions, state}
  end
end
