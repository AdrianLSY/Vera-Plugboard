defmodule Plugboard.Services.ServiceRequestRegistry do
  use GenServer

  @entity_max_age System.get_env("PHX_GENSTAGE_ENTITY_MAX_AGE") |> String.to_integer()
  @cleanup_interval System.get_env("PHX_GENSTAGE_CLEANUP_INTERVAL") |> String.to_integer()

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def init(state) do
    schedule_cleanup()
    {:ok, state}
  end

  def register_request(response_ref, pid) do
    GenServer.call(__MODULE__, {:register, response_ref, pid})
  end

  def get_requester(response_ref) do
    GenServer.call(__MODULE__, {:get, response_ref})
  end

  def handle_call({:register, response_ref, pid}, _from, state) do
    timestamp = System.system_time(:millisecond)
    {:reply, :ok, Map.put(state, response_ref, {pid, timestamp})}
  end

  def handle_call({:get, response_ref}, _from, state) do
    case Map.get(state, response_ref) do
      {pid, _timestamp} -> {:reply, pid, Map.delete(state, response_ref)}
      nil -> {:reply, nil, state}
    end
  end

  def handle_info(:cleanup, state) do
    schedule_cleanup()
    current_time = System.system_time(:millisecond)

    cleaned_state = state
    |> Enum.reject(fn {_key, {_pid, timestamp}} ->
      current_time - timestamp > @entity_max_age
    end)
    |> Map.new()

    {:noreply, cleaned_state}
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end
end
