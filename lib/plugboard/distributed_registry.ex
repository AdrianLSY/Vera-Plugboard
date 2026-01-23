defmodule Plugboard.DistributedRegistry do
  @moduledoc """
  Distributed registry for tracking telephone processes across cluster nodes.

  This module wraps Horde.Registry to provide cluster-wide telephone registration
  and lookup. Horde uses CRDTs for eventual consistency and automatically handles
  node failures and network partitions.

  ## Features
  - Automatic cluster member discovery via Horde
  - Consistent hashing for load distribution
  - Automatic failover on node failure
  - CRDT-based eventual consistency
  - Works seamlessly with remote PIDs across nodes

  ## Usage

      # Register a telephone for a path
      DistributedRegistry.register(path_id, self())

      # Look up telephone for a path
      {:ok, pid} = DistributedRegistry.get_telephone(path_id)

      # Send message to telephone (works across nodes)
      send(pid, {:proxy_request, ...})
  """

  use Horde.Registry

  # ETS table for round-robin counters
  @counter_table :plugboard_telephone_rr_counters

  # Type definitions
  @type path_id :: String.t()
  @type registration_value :: map()
  @type telephone_entry :: {pid(), registration_value()}

  @doc """
  Starts the distributed registry as part of the supervision tree.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts) do
    Horde.Registry.start_link(__MODULE__, [keys: :unique], name: __MODULE__)
  end

  @doc """
  Initializes the Horde.Registry with cluster membership configuration.

  This callback sets up:
  - Unique key registration
  - Automatic cluster member discovery
  - Delta CRDT synchronization
  """
  def init(opts) do
    # Create ETS table for atomic round-robin counters
    # This provides better distribution than timestamp-based selection
    :ets.new(@counter_table, [
      :named_table,
      :public,
      :set,
      write_concurrency: true
    ])

    members = get_cluster_members()

    [members: members]
    |> Keyword.merge(opts)
    |> Horde.Registry.init()
  end

  @doc """
  Registers the calling process for the given path_id.

  IMPORTANT: Horde.Registry can ONLY register self() (the calling process).
  The calling process (self()) will always be registered.

  Multiple processes can register for the same path_id by using unique
  registration keys ({path_id, self()}), enabling round-robin load
  balancing across multiple telephones.

  ## Parameters
    - path_id: The path ID this telephone serves
    - value: Optional metadata to store with registration

  ## Returns
    - {:ok, pid} on success where pid is self()
    - {:error, reason} on failure

  ## Examples

      iex> DistributedRegistry.register("path-123")
      {:ok, #PID<0.234.0>}  # where #PID<0.234.0> is self()
  """
  @spec register(path_id(), map() | nil) :: {:ok, pid()} | {:error, term()}
  def register(path_id, value \\ nil) do
    # Horde.Registry.register ONLY registers self(), not arbitrary PIDs
    # This is by design - processes must register themselves
    calling_pid = self()

    # Create unique key by combining path_id with calling PID
    # This allows multiple processes to register for the same path
    unique_key = {path_id, calling_pid}
    value = Map.merge(value || %{}, %{path_id: path_id, registered_at: System.system_time()})

    # Check if already registered to avoid duplicates
    # Horde.Registry.lookup returns list of {pid, value} tuples for the given key
    case Horde.Registry.lookup(__MODULE__, unique_key) do
      [] ->
        # Not registered, proceed with registration
        case Horde.Registry.register(__MODULE__, unique_key, value) do
          {:ok, _horde_pid} ->
            :telemetry.execute(
              [:plugboard, :distributed_registry, :registered],
              %{count: 1},
              %{path_id: path_id, node: node(calling_pid)}
            )

            {:ok, calling_pid}

          {:error, {:already_registered, _existing_pid}} ->
            # Race condition - another process registered between lookup and register
            {:ok, calling_pid}

          {:error, reason} = error ->
            :telemetry.execute(
              [:plugboard, :distributed_registry, :register_failed],
              %{count: 1},
              %{path_id: path_id, reason: reason}
            )

            error
        end

      [{_existing_pid, _existing_value}] ->
        # Already registered
        {:ok, calling_pid}
    end
  end

  @doc """
  Unregisters the calling process from the given path_id.

  Only the calling process (self()) can unregister itself.

  ## Parameters
    - path_id: The path ID to unregister from

  ## Examples

      iex> DistributedRegistry.unregister("path-123")
      :ok
  """
  @spec unregister(path_id()) :: :ok | {:error, term()}
  def unregister(path_id) do
    calling_pid = self()
    unique_key = {path_id, calling_pid}

    case Horde.Registry.unregister(__MODULE__, unique_key) do
      :ok ->
        :telemetry.execute(
          [:plugboard, :distributed_registry, :unregistered],
          %{count: 1},
          %{path_id: path_id, node: node(calling_pid)}
        )

        :ok

      error ->
        error
    end
  end

  @doc """
  Looks up all telephones registered for a path_id.

  Returns a list of {pid, value} tuples. Multiple telephones can be
  registered for the same path using unique keys.

  ## Parameters
    - path_id: The path ID to look up

  ## Returns
    - List of {pid, value} tuples (may be empty)

  ## Examples

      iex> DistributedRegistry.lookup("path-123")
      [{#PID<0.234.0>, %{}}, {#PID<12345.678.9>, %{}}]

      iex> DistributedRegistry.lookup("nonexistent")
      []
  """
  @spec lookup(path_id()) :: [telephone_entry()]
  def lookup(path_id) do
    # Find all registrations where the key matches {path_id, _pid}
    # The registry stores keys as tuples: {path_id, pid}
    # Use match specification to filter at the registry level (more efficient than full scan)
    # Pattern: {{path_id, _any_pid}, pid, value} -> {pid, value}
    Horde.Registry.select(__MODULE__, [
      {{{path_id, :_}, :"$1", :"$2"}, [], [{{:"$1", :"$2"}}]}
    ])
  end

  @doc """
  Gets a single telephone for the given path_id using round-robin selection.

  When multiple telephones are registered for a path, this function selects
  one using a simple round-robin strategy based on the current timestamp.

  ## Parameters
    - path_id: The path ID to look up

  ## Returns
    - {:ok, pid} if at least one telephone is available
    - {:error, :no_telephone} if no telephones are registered

  ## Examples

      iex> DistributedRegistry.get_telephone("path-123")
      {:ok, #PID<0.234.0>}

      iex> DistributedRegistry.get_telephone("nonexistent")
      {:error, :no_telephone}
  """
  @spec get_telephone(path_id()) :: {:ok, pid()} | {:error, :no_telephone}
  def get_telephone(path_id) do
    case lookup(path_id) do
      [] ->
        {:error, :no_telephone}

      telephones when is_list(telephones) ->
        # Use atomic counter for true round-robin distribution
        # This prevents hotspots from sequential requests hitting the same telephone
        count = :ets.update_counter(@counter_table, path_id, {2, 1}, {path_id, 0})
        index = rem(count, length(telephones))
        {pid, _value} = Enum.at(telephones, index)

        {:ok, pid}
    end
  end

  @doc """
  Returns the count of telephones registered for a path_id.

  ## Examples

      iex> DistributedRegistry.count_telephones("path-123")
      2

      iex> DistributedRegistry.count_telephones("nonexistent")
      0
  """
  @spec count_telephones(path_id()) :: non_neg_integer()
  def count_telephones(path_id) do
    path_id
    |> lookup()
    |> length()
  end

  @doc """
  Lists all path_ids that have at least one telephone registered.

  Note: This performs a full scan of the registry and may be expensive.
  Use sparingly in production.

  ## Examples

      iex> DistributedRegistry.list_active_paths()
      ["path-123", "path-456"]
  """
  @spec list_active_paths() :: [path_id()]
  def list_active_paths do
    # This is an expensive operation - use only for debugging/monitoring
    # Extract path_id from {path_id, pid} tuple keys
    __MODULE__
    |> Horde.Registry.select([{{{:"$1", :_}, :_, :_}, [], [:"$1"]}])
    |> Enum.uniq()
  end

  @doc """
  Returns statistics about the registry across all cluster nodes.

  ## Returns
    Map with:
    - :active_paths - Number of unique paths with telephones
    - :total_telephones - Total number of registered telephones
    - :nodes - Number of nodes in cluster
    - :this_node - Current node name

  ## Examples

      iex> DistributedRegistry.stats()
      %{
        active_paths: 10,
        total_telephones: 25,
        nodes: 3,
        this_node: :"plugboard@127.0.0.1"
      }
  """
  @spec stats() :: %{
          active_paths: non_neg_integer(),
          total_telephones: non_neg_integer(),
          nodes: non_neg_integer(),
          this_node: node()
        }
  def stats do
    paths = list_active_paths()

    total_telephones =
      Enum.reduce(paths, 0, fn path_id, acc ->
        acc + count_telephones(path_id)
      end)

    %{
      active_paths: length(paths),
      total_telephones: total_telephones,
      nodes: length(Horde.Cluster.members(__MODULE__)),
      this_node: node()
    }
  end

  @doc """
  Returns the list of Horde cluster members.

  ## Examples

      iex> DistributedRegistry.members()
      [
        {Plugboard.DistributedRegistry, :"plugboard@10.0.1.1"},
        {Plugboard.DistributedRegistry, :"plugboard@10.0.1.2"}
      ]
  """
  @spec members() :: [{module(), node()}]
  def members do
    Horde.Cluster.members(__MODULE__)
  end

  @doc """
  Adds a node to the Horde cluster membership.

  This is typically called automatically by Horde when nodes join the cluster,
  but can be manually triggered if needed.

  ## Parameters
    - node_name: The node to add (e.g., :"plugboard@10.0.1.2")

  ## Examples

      iex> DistributedRegistry.add_node(:"plugboard@10.0.1.2")
      :ok
  """
  @spec add_node(node()) :: :ok
  def add_node(node_name) when is_atom(node_name) do
    Horde.Cluster.set_members(
      __MODULE__,
      [{__MODULE__, node_name} | Horde.Cluster.members(__MODULE__)]
    )
  end

  ## Private Functions

  # Gets the initial cluster members from all connected nodes
  defp get_cluster_members do
    # Get all connected nodes including self
    nodes = [node() | Node.list()]

    # Create Horde member tuples for each node
    Enum.map(nodes, fn node_name ->
      {__MODULE__, node_name}
    end)
  end
end
