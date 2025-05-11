defmodule Plugboard.Services.ServiceConsumerRegistry do
  @moduledoc """
  A GenServer that manages service resources using ETS:

  1. Service Consumers: Processes listening on PlugboardWeb.Services.ServiceConsumerChannel
  2. Service Actions: Maps describing what services can execute and their parameters
  3. Service Requests: Mappings between response references and requesting process PIDs

  Registration and unregistration operations are handled by GenServer calls to ensure consistency.
  Read operations access ETS tables directly for better performance.

  The registry also performs automatic cleanup of old request entries based on configured intervals.
  """
  use GenServer
  alias Phoenix.PubSub

  # Configuration for request cleanup
  @entity_max_age System.get_env("PHX_GENSTAGE_ENTITY_MAX_AGE") |> String.to_integer()
  @cleanup_interval System.get_env("PHX_GENSTAGE_CLEANUP_INTERVAL") |> String.to_integer()

  #
  # Client API
  #

  @doc """
  Starts the service registry for a specific service.
  For request registry, pass service_id: :request_registry
  """
  def start_link(opts) do
    service_id = Keyword.fetch!(opts, :service_id)
    name = via_tuple(service_id)
    GenServer.start_link(__MODULE__, %{service_id: service_id}, name: name)
  end

  @doc """
  Creates a unique name for the GenServer based on the service_id
  """
  def via_tuple(service_id) do
    {:via, Registry,
     {Plugboard.Services.ServiceConsumerRegistry, {__MODULE__, to_string(service_id)}}}
  end

  #
  # Consumer Management
  #

  @doc """
  Get the ETS table name for consumers of a specific service
  """
  def consumers_table_name(service_id) do
    :"service_#{service_id}_consumers"
  end

  @doc """
  Registers a consumer for the given service_id.
  """
  def register_consumer(service_id, pid) when is_pid(pid) do
    GenServer.call(via_tuple(service_id), {:register_consumer, pid, service_id})
  end

  @doc """
  Unregisters a consumer for the given service_id.
  """
  def unregister_consumer(service_id, pid) when is_pid(pid) do
    GenServer.call(via_tuple(service_id), {:unregister_consumer, pid, service_id})
  end

  @doc """
  Returns the list of consumer pids for a given service
  """
  def consumers(service_id) do
    table_name = consumers_table_name(service_id)

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
  def cycle_consumers(service_id) do
    table_name = consumers_table_name(service_id)
    pids = :ets.tab2list(table_name) |> Enum.map(fn {pid} -> pid end)

    case pids do
      [] ->
        nil

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
  def num_consumers(service_id) do
    table_name = consumers_table_name(service_id)

    case :ets.info(table_name, :size) do
      :undefined -> 0
      size -> size
    end
  end

  #
  # Action Management
  #

  @doc """
  Get the ETS table name for actions of a specific service
  """
  def actions_table_name(service_id) do
    :"service_#{service_id}_actions"
  end

  @doc """
  Registers actions for the given service_id.
  """
  def register_actions(service_id, actions) when is_map(actions) do
    GenServer.call(via_tuple(service_id), {:register_actions, actions})
  end

  @doc """
  Unregisters actions for the given service_id.
  """
  def unregister_actions(service_id) do
    GenServer.call(via_tuple(service_id), {:unregister_actions})
  end

  @doc """
  Returns the actions for the given service_id.
  If the service_id is not found, an empty map is returned.
  """
  def actions(service_id) do
    table_name = actions_table_name(service_id)

    try do
      case :ets.lookup(table_name, "actions") do
        [{_key, actions}] -> actions
        [] -> %{}
      end
    rescue
      _ -> %{}
    end
  end

  #
  # Request Management
  #

  @doc """
  Get the ETS table name for requests of a specific service
  """
  def requests_table_name(service_id) do
    :"service_#{service_id}_requests"
  end

  @doc """
  Registers a request with the given response_ref and requesting process pid.
  """
  def register_request(service_id, response_ref, pid) when is_pid(pid) do
    GenServer.cast(via_tuple(service_id), {:register_request, response_ref, pid})
  end

  @doc """
  Gets the process that made a request with the given response_ref.
  Returns the pid if found, nil otherwise. Deletes the entry after retrieving it.
  """
  def get_requester(service_id, response_ref) do
    table_name = requests_table_name(service_id)

    try do
      case :ets.lookup(table_name, response_ref) do
        [{^response_ref, pid, _timestamp}] ->
          GenServer.cast(via_tuple(service_id), {:unregister_request, response_ref})
          pid

        [] ->
          nil
      end
    rescue
      _ -> nil
    end
  end

  #
  # Server Callbacks
  #

  @doc false
  def init(%{service_id: service_id}) do
    # Initialize consumer table
    consumers_table = :ets.new(consumers_table_name(service_id), [:named_table, :set])

    # Initialize actions table
    actions_table =
      :ets.new(actions_table_name(service_id), [
        :set,
        :named_table,
        :protected,
        read_concurrency: true
      ])

    # Initialize requests table
    requests_table =
      :ets.new(requests_table_name(service_id), [
        :set,
        :named_table,
        :protected,
        read_concurrency: true
      ])

    # Schedule cleanup for requests
    schedule_cleanup()

    {:ok,
     %{
       consumers_table: consumers_table,
       actions_table: actions_table,
       requests_table: requests_table,
       service_id: service_id
     }}
  end

  # Consumer handlers
  @doc false
  def handle_call({:register_consumer, pid, service_id}, _from, state) do
    Process.monitor(pid)
    :ets.insert(state.consumers_table, {pid})

    PubSub.broadcast(
      Plugboard.PubSub,
      "service/#{service_id}",
      {:num_consumers, num_consumers(service_id)}
    )

    {:reply, :ok, state}
  end

  @doc false
  def handle_call({:unregister_consumer, pid, service_id}, _from, state) do
    :ets.delete(state.consumers_table, pid)

    PubSub.broadcast(
      Plugboard.PubSub,
      "service/#{service_id}",
      {:num_consumers, num_consumers(service_id)}
    )

    {:reply, :ok, state}
  end

  # Action handlers
  @doc false
  def handle_call({:register_actions, actions}, _from, state) do
    :ets.insert(state.actions_table, {"actions", actions})

    PubSub.broadcast(
      Plugboard.PubSub,
      "service/#{state.service_id}",
      {:actions, actions}
    )

    {:reply, :ok, state}
  end

  @doc false
  def handle_call({:unregister_actions}, _from, state) do
    :ets.delete(state.actions_table, "actions")

    PubSub.broadcast(
      Plugboard.PubSub,
      "service/#{state.service_id}",
      {:actions, %{}}
    )

    {:reply, :ok, state}
  end

  # Request handlers
  @doc false
  def handle_cast({:register_request, response_ref, pid}, state) do
    timestamp = System.system_time(:millisecond)
    :ets.insert(state.requests_table, {response_ref, pid, timestamp})
    {:noreply, state}
  end

  def handle_cast({:unregister_request, response_ref}, state) do
    :ets.delete(state.requests_table, response_ref)
    {:noreply, state}
  end

  # Process monitoring for consumers
  @doc false
  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{service_id: service_id} = state)
      when service_id != :request_registry do
    :ets.delete(state.consumers_table, pid)

    PubSub.broadcast(
      Plugboard.PubSub,
      "service/#{service_id}",
      {:num_consumers, num_consumers(service_id)}
    )

    {:noreply, state}
  end

  # Cleanup for requests
  @doc false
  def handle_info(:cleanup, state) do
    schedule_cleanup()
    current_time = System.system_time(:millisecond)

    # Find all entries older than the max age
    :ets.select_delete(state.requests_table, [
      {{:_, :_, :"$1"}, [{:>, {:-, current_time, :"$1"}, @entity_max_age}], [true]}
    ])

    {:noreply, state}
  end

  # Ignore other messages
  def handle_info(_, state), do: {:noreply, state}

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end
end
