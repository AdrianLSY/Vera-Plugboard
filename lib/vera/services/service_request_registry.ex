defmodule Vera.Services.ServiceRequestRegistry do
  use GenServer

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def init(state) do
    {:ok, state}
  end

  def register_request(response_ref, pid) do
    GenServer.call(__MODULE__, {:register, response_ref, pid})
  end

  def get_requester(response_ref) do
    GenServer.call(__MODULE__, {:get, response_ref})
  end

  def handle_call({:register, response_ref, pid}, _from, state) do
    {:reply, :ok, Map.put(state, response_ref, pid)}
  end

  def handle_call({:get, response_ref}, _from, state) do
    {:reply, Map.get(state, response_ref), Map.delete(state, response_ref)}
  end
end
