defmodule Plugboard.TelephoneRegistry do
  @moduledoc """
  Registry for tracking connected telephone processes across cluster nodes.

  ## Compatibility Shim Pattern

  **This module is a compatibility shim** that delegates all operations to
  `Plugboard.DistributedRegistry` (Horde-based). It exists to maintain backward
  compatibility with code written during Phase 5 of development, when telephone
  tracking used local ETS tables.

  ### Why Keep This Shim?

  1. **Gradual Migration**: Allows existing code to continue working without
     changes while the underlying implementation evolved from ETS to Horde.

  2. **API Stability**: External code and tests reference `TelephoneRegistry`,
     not `DistributedRegistry`. Changing all call sites would be disruptive.

  3. **Semantic Clarity**: The name "TelephoneRegistry" clearly describes its
     purpose (tracking telephones), while "DistributedRegistry" is more generic.

  ### Implementation Details

  - `start_link/1` returns `:ignore` - no process is started since
    `DistributedRegistry` handles the actual registration.
  - All other functions delegate directly to `DistributedRegistry`.
  - Return values are normalized (e.g., `{:ok, pid}` → `:ok` for `register/2`).

  ## Cluster Operation

  With Horde.Registry (via DistributedRegistry):
  - Telephones can connect to any node
  - Requests on any node can reach any telephone
  - Automatic failover when nodes leave cluster
  - CRDT-based eventual consistency

  ## Future Considerations

  This shim may be removed in a future major version. When that happens:
  1. Update all call sites to use `DistributedRegistry` directly
  2. Remove this module
  3. Update the supervision tree (currently expects this module)
  """

  alias Plugboard.DistributedRegistry

  require Logger

  # Type definitions
  @type path_id :: String.t()

  @doc """
  Starts the TelephoneRegistry.

  This is a no-op in Phase 6 since DistributedRegistry handles the actual
  registration. Kept for backwards compatibility with existing supervision tree.
  """
  @spec start_link(keyword()) :: :ignore
  def start_link(_opts) do
    # No-op: DistributedRegistry is started separately
    # Return :ignore to tell supervisor this child doesn't need to be started
    Logger.info("TelephoneRegistry: Using DistributedRegistry for cluster-wide operation")
    :ignore
  end

  @doc """
  Registers a telephone channel for a given path.

  Delegates to DistributedRegistry for cluster-wide registration.

  ## Parameters
    - path_id: The path ID this telephone serves
    - telephone_pid: The PID of the telephone channel process

  ## Returns
    - :ok on success
    - {:error, reason} on failure
  """
  @spec register(path_id(), pid()) :: :ok | {:error, term()}
  def register(path_id, telephone_pid) when is_binary(path_id) and is_pid(telephone_pid) do
    case DistributedRegistry.register(path_id, telephone_pid) do
      {:ok, _pid} -> :ok
      error -> error
    end
  end

  @doc """
  Unregisters a telephone channel from a path.

  Delegates to DistributedRegistry.

  ## Parameters
    - path_id: The path ID to unregister from
    - telephone_pid: The PID of the telephone channel process
  """
  @spec unregister(path_id(), pid()) :: :ok | {:error, term()}
  def unregister(path_id, telephone_pid) when is_binary(path_id) and is_pid(telephone_pid) do
    DistributedRegistry.unregister(path_id, telephone_pid)
  end

  @doc """
  Gets the next available telephone for a path using round-robin.

  Delegates to DistributedRegistry which handles load balancing across
  all registered telephones, regardless of which node they're on.

  ## Parameters
    - path_id: The path ID to look up

  ## Returns
    - {:ok, pid} if a telephone is available
    - {:error, :no_telephone} if no telephones are registered
  """
  @spec get_telephone(path_id()) :: {:ok, pid()} | {:error, :no_telephone}
  def get_telephone(path_id) when is_binary(path_id) do
    DistributedRegistry.get_telephone(path_id)
  end

  @doc """
  Lists all telephones registered to a path.

  Returns PIDs from all nodes in the cluster.

  ## Parameters
    - path_id: The path ID to query

  ## Returns
    - List of PIDs registered for the path
  """
  @spec list_telephones(path_id()) :: [pid()]
  def list_telephones(path_id) when is_binary(path_id) do
    path_id
    |> DistributedRegistry.lookup()
    |> Enum.map(fn {pid, _value} -> pid end)
  end

  @doc """
  Counts the number of telephones registered to a path.

  Includes telephones from all nodes in the cluster.

  ## Parameters
    - path_id: The path ID to count

  ## Returns
    - Integer count of registered telephones
  """
  @spec count_telephones(path_id()) :: non_neg_integer()
  def count_telephones(path_id) when is_binary(path_id) do
    DistributedRegistry.count_telephones(path_id)
  end

  @doc """
  Lists all paths that have at least one telephone registered.

  Scans the distributed registry across all cluster nodes.

  Note: This is an expensive operation. Use sparingly.

  ## Returns
    - List of path_id strings
  """
  @spec list_active_paths() :: [path_id()]
  def list_active_paths do
    DistributedRegistry.list_active_paths()
  end

  @doc """
  Gets statistics about the registry across all cluster nodes.

  ## Returns
    Map with:
    - :active_paths - Number of unique paths with telephones
    - :total_telephones - Total number of registered telephones across cluster
    - :nodes - Number of nodes in cluster
    - :this_node - Current node name

  ## Examples

      iex> TelephoneRegistry.stats()
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
    DistributedRegistry.stats()
  end

  @doc """
  Returns the list of Horde cluster members.

  Useful for monitoring and debugging cluster state.

  ## Examples

      iex> TelephoneRegistry.members()
      [
        {Plugboard.DistributedRegistry, :"plugboard@10.0.1.1"},
        {Plugboard.DistributedRegistry, :"plugboard@10.0.1.2"}
      ]
  """
  @spec members() :: [{module(), node()}]
  def members do
    DistributedRegistry.members()
  end
end
