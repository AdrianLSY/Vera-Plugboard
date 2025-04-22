defmodule Plugboard.Services.ServiceConsumerRegistry do
  @moduledoc """
  A GenServer that manages service consumers using ETS.
  A consumer is a process that is listening in on PlugboardWeb.Services.ServiceConsumerChannel
  This genserver is deployed for each individual service and is responsible for managing its consumers.

  Registration and unregistration of consumers are handled by genserver calls to ensure consistency.
  Running consumers(), cycle() and length will directly return the data from the ETS table directly.
  """
  use GenServer

  @doc false
  def start_link(opts) do
    service_id = Keyword.fetch!(opts, :service_id)
    name = via_tuple(service_id)
    GenServer.start_link(__MODULE__, %{service_id: service_id}, name: name)
  end

  @doc """
  Creates a unique name for the GenServer based on the service_id
  """
  def via_tuple(service_id) do
    {:via, Registry, {Plugboard.Services.ServiceRegistry, {__MODULE__, to_string(service_id)}}}
  end

  @doc """
  Get the ETS table name for a specific service
  """
  def table_name(service_id) do
    :"service_#{service_id}_consumers"
  end

  @doc """
  Registers the consumer for the given service_id.
  """
  def register(service_id, pid) when is_pid(pid) do
    GenServer.call(via_tuple(service_id), {:register, pid, service_id})
  end

  @doc """
  Unregisters the consumer for the given service_id.
  """
  def unregister(service_id, pid) when is_pid(pid) do
    GenServer.call(via_tuple(service_id), {:unregister, pid, service_id})
  end

  @doc """
  Returns the list of consumer pids
  """
  def consumers(service_id) do
    table_name = table_name(service_id)
    try do
      :ets.tab2list(table_name) |> Enum.map(fn {pid} -> pid end)
    rescue
      _ -> []
    end
  end

  @doc """
  Cycles through the consumers for a given service. Returns the next consumer pid.
  This will effectively round-robin through the consumers.
  """
  def cycle(service_id) do
    table_name = table_name(service_id)
    pids = :ets.tab2list(table_name) |> Enum.map(fn {pid} -> pid end)
    case pids do
      [] -> nil
      pids ->
        current_index = Process.get({:cycle_index, service_id}, 0)
        next_index = rem(current_index + 1, length(pids))
        Process.put({:cycle_index, service_id}, next_index)
        Enum.at(pids, current_index)
    end
  end

  @doc """
  Returns the number of consumers for a given service
  """
  def consumers_connected(service_id) do
    table_name = table_name(service_id)
    :ets.info(table_name, :size)
  end

  @doc false
  def init(%{service_id: service_id}) do
    table_name = table_name(service_id)
    table = :ets.new(table_name, [:named_table, :set])
    {:ok, %{table: table, service_id: service_id, current_index: 0}}
  end

  @doc false
  def handle_call({:register, pid, service_id}, _from, state) do
    Process.monitor(pid)
    :ets.insert(state.table, {pid})
    Phoenix.PubSub.broadcast(Plugboard.PubSub, "service/#{service_id}", {:consumers_connected, consumers_connected(service_id)})
    {:reply, :ok, state}
  end

  @doc false
  def handle_call({:unregister, pid, service_id}, _from, state) do
    :ets.delete(state.table, pid)
    Phoenix.PubSub.broadcast(Plugboard.PubSub, "service/#{service_id}", {:consumers_connected, consumers_connected(service_id)})
    {:reply, :ok, state}
  end

  @doc false
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    :ets.delete(state.table, pid)
    {:noreply, state}
  end
end
