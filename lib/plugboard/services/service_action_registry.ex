defmodule Plugboard.Services.ServiceActionRegistry do
  @moduledoc """
  A GenServer that manages service actions using ETS.
  An action is a map that describes what the service can execute and its associated parameters.
  This genserver is deployed for each individual service and is responsible for managing its actions.

  Registration and unregistration of actions are handled by genserver calls to ensure consistency.
  Running actions() will return the data from the ETS table directly bypassing the GenServer for performance.
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
    :"service_#{service_id}_actions"
  end

  @doc false
  def init(%{service_id: service_id}) do
    table_name = table_name(service_id)
    table = :ets.new(table_name, [
      :set,
      :named_table,
      :protected,
      read_concurrency: true
    ])

    {:ok, %{table: table, service_id: service_id}}
  end

  @doc """
  Registers the action for the given service_id.
  """
  def register(service_id, action) when is_map(action) do
    GenServer.call(via_tuple(service_id), {:register, action})
  end

  @doc """
  Unregisters the action for the given service_id.
  """
  def unregister(service_id) do
    GenServer.call(via_tuple(service_id), :unregister)
  end

  @doc """
  Returns the actions for the given service_id.
  If the service_id is not found, an empty map is returned.
  """
  def actions(service_id) do
    table_name = table_name(service_id)
    try do
      case :ets.lookup(table_name, "actions") do
        [{_key, actions}] -> actions
        [] -> %{}
      end
    rescue
      _ -> %{}
    end
  end

  @doc false
  def handle_call({:register, action}, _from, state) do
    :ets.insert(state.table, {"actions", action})
    Phoenix.PubSub.broadcast(Plugboard.PubSub, "service/#{state.service_id}", {:actions, action})
    {:reply, :ok, state}
  end

  @doc false
  def handle_call(:unregister, _from, state) do
    :ets.delete(state.table, "actions")
    Phoenix.PubSub.broadcast(Plugboard.PubSub, "service/#{state.service_id}", {:actions, %{}})
    {:reply, :ok, state}
  end
end
