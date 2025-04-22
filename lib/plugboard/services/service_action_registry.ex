defmodule Plugboard.Services.ServiceActionRegistry do
  @moduledoc """
  A GenServer that manages service actions using ETS.
  An action is a map that describes what the service can execute and its associated parameters.

  Registration and unregistration of actions are handled by genserver casts to ensure consistency.
  Running get_actions(service_id) will directly return the data from the ETS table directly.
  """
  use GenServer

  @table_name :service_actions

  @doc false
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
  def register(service_id, action) when is_map(action) do
    GenServer.cast(__MODULE__, {:register, service_id, action})
  end

  @doc """
  Unregisters the action for the given service_id.
  """
  def unregister(service_id) do
    GenServer.cast(__MODULE__, {:unregister, service_id})
  end

  @doc """
  Returns the actions for the given service_id.
  If the service_id is not found, an empty map is returned.
  """
  def get_actions(service_id) do
    case :ets.lookup(@table_name, service_id |> to_string) do
      [{_id, actions}] -> actions  # Match any id, return the actions
      [] -> %{}
    end
  end

  @doc false
  def handle_cast({:register, service_id, action}, state) do
    :ets.insert(@table_name, {service_id |> to_string, action})
    Phoenix.PubSub.broadcast(Plugboard.PubSub, "service/#{service_id}", {:actions, action})
    {:noreply, state}
  end

  @doc false
  def handle_cast({:unregister, service_id}, state) do
    :ets.delete(@table_name, service_id |> to_string)
    Phoenix.PubSub.broadcast(Plugboard.PubSub, "service/#{service_id}", {:actions, %{}})
    {:noreply, state}
  end
end
