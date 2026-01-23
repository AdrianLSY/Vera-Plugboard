defmodule Plugboard.WebSocketProxyRegistry do
  @moduledoc """
  ETS-based registry for tracking active WebSocket proxy connections.

  This registry maintains a mapping of connection IDs to handler processes,
  enabling telemetry, monitoring, and connection management.

  ## Data Structure

  The ETS table stores entries in the format:
  `{connection_id, handler_pid, path_id, telephone_pid, connected_at}`

  ## Usage

      # Register a new connection
      :ok = WebSocketProxyRegistry.register(conn_id, handler_pid, path_id, telephone_pid)

      # Look up a connection
      {:ok, info} = WebSocketProxyRegistry.lookup(conn_id)

      # Unregister when done
      :ok = WebSocketProxyRegistry.unregister(conn_id)

      # Get connection count for a path
      count = WebSocketProxyRegistry.count_for_path(path_id)
  """

  use GenServer

  @table :plugboard_websocket_proxy_connections
  @path_index_table :plugboard_websocket_proxy_path_index

  ## Client API

  @doc """
  Starts the WebSocketProxyRegistry.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Registers a new WebSocket proxy connection.

  ## Parameters

    * `connection_id` - Unique identifier for the connection
    * `handler_pid` - PID of the WebSocketProxyHandler process
    * `path_id` - The path ID this connection is proxying for
    * `telephone_pid` - PID of the TelephoneChannel handling this connection

  ## Returns

    * `:ok` on success
    * `{:error, :already_registered}` if connection_id already exists
  """
  @spec register(String.t(), pid(), String.t(), pid()) :: :ok | {:error, :already_registered}
  def register(connection_id, handler_pid, path_id, telephone_pid) do
    GenServer.call(__MODULE__, {:register, connection_id, handler_pid, path_id, telephone_pid})
  end

  @doc """
  Looks up a connection by its ID.

  ## Returns

    * `{:ok, %{handler_pid: pid, path_id: string, telephone_pid: pid, connected_at: integer}}`
    * `{:error, :not_found}` if connection doesn't exist
  """
  @spec lookup(String.t()) ::
          {:ok,
           %{
             handler_pid: pid(),
             path_id: String.t(),
             telephone_pid: pid(),
             connected_at: integer()
           }}
          | {:error, :not_found}
  def lookup(connection_id) do
    case :ets.lookup(@table, connection_id) do
      [{^connection_id, handler_pid, path_id, telephone_pid, connected_at}] ->
        {:ok,
         %{
           handler_pid: handler_pid,
           path_id: path_id,
           telephone_pid: telephone_pid,
           connected_at: connected_at
         }}

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Unregisters a WebSocket proxy connection.

  ## Returns

    * `:ok` regardless of whether the connection existed
  """
  @spec unregister(String.t()) :: :ok
  def unregister(connection_id) do
    GenServer.call(__MODULE__, {:unregister, connection_id})
  end

  # Internal unregister function called from within GenServer process
  # (which owns the protected ETS table)
  defp do_unregister(connection_id) do
    case :ets.lookup(@table, connection_id) do
      [{^connection_id, _handler_pid, path_id, _telephone_pid, connected_at}] ->
        :ets.delete(@table, connection_id)
        :ets.match_delete(@path_index_table, {path_id, connection_id})

        duration_ms = System.monotonic_time(:millisecond) - connected_at

        :telemetry.execute(
          [:plugboard, :websocket_proxy, :unregistered],
          %{count: 1, duration_ms: duration_ms},
          %{connection_id: connection_id, path_id: path_id}
        )

      [] ->
        :ok
    end

    :ok
  end

  @doc """
  Returns the count of active connections for a specific path.
  """
  @spec count_for_path(String.t()) :: non_neg_integer()
  def count_for_path(path_id) do
    :ets.match(@path_index_table, {path_id, :_}) |> length()
  end

  @doc """
  Returns the total count of active WebSocket proxy connections.
  """
  @spec count_all() :: non_neg_integer()
  def count_all do
    :ets.info(@table, :size)
  end

  @doc """
  Returns all active connections (for debugging/monitoring).
  """
  @spec list_all() :: [
          %{
            connection_id: String.t(),
            handler_pid: pid(),
            path_id: String.t(),
            telephone_pid: pid(),
            connected_at: integer()
          }
        ]
  def list_all do
    :ets.tab2list(@table)
    |> Enum.map(fn {connection_id, handler_pid, path_id, telephone_pid, connected_at} ->
      %{
        connection_id: connection_id,
        handler_pid: handler_pid,
        path_id: path_id,
        telephone_pid: telephone_pid,
        connected_at: connected_at
      }
    end)
  end

  ## Server Callbacks

  @impl true
  def init(_opts) do
    # Create ETS tables with :protected access
    # Only this GenServer can write; other processes can only read
    # This prevents external processes from corrupting the registry
    :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])

    :ets.new(@path_index_table, [:named_table, :protected, :bag, read_concurrency: true])

    {:ok, %{}}
  end

  @impl true
  def handle_call({:register, connection_id, handler_pid, path_id, telephone_pid}, _from, state) do
    case :ets.insert_new(@table, {connection_id, handler_pid, path_id, telephone_pid, now()}) do
      true ->
        # Also index by path_id for efficient counting
        :ets.insert(@path_index_table, {path_id, connection_id})

        # Monitor the handler process for cleanup (from within GenServer)
        Process.monitor(handler_pid)

        :telemetry.execute(
          [:plugboard, :websocket_proxy, :registered],
          %{count: 1},
          %{connection_id: connection_id, path_id: path_id}
        )

        {:reply, :ok, state}

      false ->
        {:reply, {:error, :already_registered}, state}
    end
  end

  @impl true
  def handle_call({:unregister, connection_id}, _from, state) do
    do_unregister(connection_id)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    # Handler process died, clean up its connection(s)
    # A single handler PID could theoretically have multiple connections
    connection_ids = :ets.match(@table, {:"$1", pid, :_, :_, :_}) |> List.flatten()

    case connection_ids do
      [] ->
        :ok

      ids ->
        Enum.each(ids, fn connection_id ->
          do_unregister(connection_id)
        end)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  ## Private Functions

  defp now, do: System.monotonic_time(:millisecond)
end
