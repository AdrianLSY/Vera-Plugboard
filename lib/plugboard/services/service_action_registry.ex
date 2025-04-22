defmodule Plugboard.Services.ServiceActionRegistry do
  @moduledoc """
  A GenServer that manages service actions using ETS.

  Registration and unregistration of actions are handled by genserver casts to ensure consistency.
  Reading data from the ServiceActionRegistry is done via reading from the ETS table directly preventing locking.
  """
  use GenServer

  @table_name :service_actions

  @doc """
  Starts the ServiceActionRegistry GenServer.
  """
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc false
  def init(_state) do
    table = :ets.new(@table_name, [
      :set,
      :named_table,
      :protected,
      read_concurrency: true
    ])

    {:ok, %{table: table}}
  end

  @doc """
  Registers the action for the given service_id.
  """
  def register(service_id, action) do
    GenServer.cast(__MODULE__, {:register, to_string(service_id), action})
  end

  @doc """
  Unregisters the action for the given service_id.
  """
  def unregister(service_id) do
    GenServer.cast(__MODULE__, {:unregister, to_string(service_id)})
  end

  @doc """
  Returns the actions for the given service_id.
  If the service_id is not found, an empty map is returned.
  """
  def get_actions(service_id) do
    service_id = to_string(service_id)
    case :ets.lookup(@table_name, service_id) do
      [{^service_id, actions}] -> actions
      [] -> %{}
    end
  end

  @doc false
  def handle_cast({:register, service_id, action}, state) do
    :ets.insert(@table_name, {service_id, action})
    Phoenix.PubSub.broadcast(Plugboard.PubSub, "service/#{service_id}", {:actions, action})
    {:noreply, state}
  end

  @doc false
  def handle_cast({:unregister, service_id}, state) do
    :ets.delete(@table_name, service_id)
    Phoenix.PubSub.broadcast(Plugboard.PubSub, "service/#{service_id}", {:actions, %{}})
    {:noreply, state}
  end
end
