defmodule Plugboard.ClusterConnector do
  @moduledoc """
  Handles cluster topology changes and syncs them with Horde.

  This GenServer listens to node up/down events from libcluster and ensures
  that Horde.Registry knows about cluster topology changes. This enables
  automatic redistribution of telephone registrations when nodes join or leave.

  ## Responsibilities
  - Monitor node connections via :net_kernel
  - Add new nodes to Horde cluster membership
  - Log cluster topology changes
  - Emit telemetry for cluster events

  ## Integration with libcluster
  libcluster handles node discovery and connection. ClusterConnector ensures
  Horde is updated when libcluster establishes or loses connections.
  """

  use GenServer

  alias Plugboard.DistributedRegistry

  @doc """
  Starts the ClusterConnector GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  ## GenServer Callbacks

  @impl true
  def init(_opts) do
    # Monitor node connections
    :net_kernel.monitor_nodes(true, node_type: :visible)

    {:ok, %{}}
  end

  @impl true
  def handle_info({:nodeup, node, _info}, state) do
    # Add the new node to Horde cluster membership
    case DistributedRegistry.add_node(node) do
      :ok ->
        # Emit telemetry
        :telemetry.execute(
          [:plugboard, :cluster, :node_joined],
          %{count: 1},
          %{node: node, cluster_size: length(Node.list()) + 1}
        )

      error ->
        :telemetry.execute(
          [:plugboard, :cluster, :add_node_failed],
          %{count: 1},
          %{node: node, error: error}
        )
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:nodedown, node, _info}, state) do
    # Horde automatically handles node removal via CRDT synchronization
    # No explicit action needed - registrations will be redistributed

    # Emit telemetry
    :telemetry.execute(
      [:plugboard, :cluster, :node_left],
      %{count: 1},
      %{node: node, cluster_size: length(Node.list()) + 1}
    )

    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end
end
