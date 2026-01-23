defmodule Plugboard.ClusterConnectorTest do
  @moduledoc """
  Tests for ClusterConnector - handles cluster topology changes and syncs with Horde.
  """
  use Plugboard.DataCase, async: false

  alias Plugboard.ClusterConnector

  describe "initialization" do
    test "ClusterConnector process is alive and registered" do
      assert Process.whereis(ClusterConnector) != nil
      assert Process.alive?(Process.whereis(ClusterConnector))
    end

    test "initializes with empty state" do
      pid = Process.whereis(ClusterConnector)
      state = :sys.get_state(pid)
      assert state == %{}
    end
  end

  describe "handle_info {:nodeup, ...}" do
    test "logs when node joins cluster" do
      pid = Process.whereis(ClusterConnector)

      # Simulate nodeup event (note: in real cluster this comes from :net_kernel)
      # We send directly to test the handler
      send(pid, {:nodeup, :"fake_node@127.0.0.1", []})

      # Give it time to process
      Process.sleep(50)

      # Process should still be alive
      assert Process.alive?(pid)
    end

    test "emits telemetry on nodeup" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:plugboard, :cluster, :node_joined]
        ])

      pid = Process.whereis(ClusterConnector)

      # Simulate nodeup event
      send(pid, {:nodeup, :"telemetry_test_node@127.0.0.1", []})

      # Verify telemetry was emitted
      assert_receive {[:plugboard, :cluster, :node_joined], ^ref, %{count: 1},
                      %{node: :"telemetry_test_node@127.0.0.1", cluster_size: _}},
                     1000

      :telemetry.detach(ref)
    end
  end

  describe "handle_info {:nodedown, ...}" do
    test "logs when node leaves cluster" do
      pid = Process.whereis(ClusterConnector)

      # Simulate nodedown event
      send(pid, {:nodedown, :"departed_node@127.0.0.1", []})

      # Give it time to process
      Process.sleep(50)

      # Process should still be alive
      assert Process.alive?(pid)
    end

    test "emits telemetry on nodedown" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:plugboard, :cluster, :node_left]
        ])

      pid = Process.whereis(ClusterConnector)

      # Simulate nodedown event
      send(pid, {:nodedown, :"departed_test_node@127.0.0.1", []})

      # Verify telemetry was emitted
      assert_receive {[:plugboard, :cluster, :node_left], ^ref, %{count: 1},
                      %{node: :"departed_test_node@127.0.0.1", cluster_size: _}},
                     1000

      :telemetry.detach(ref)
    end
  end

  describe "handle_info unexpected messages" do
    test "handles unexpected messages gracefully" do
      pid = Process.whereis(ClusterConnector)

      # Send unexpected message
      send(pid, {:unexpected_message, :some_data})

      # Give it time to process
      Process.sleep(50)

      # Process should still be alive
      assert Process.alive?(pid)
    end

    test "handles nil messages" do
      pid = Process.whereis(ClusterConnector)

      send(pid, nil)

      Process.sleep(50)

      assert Process.alive?(pid)
    end
  end

  describe "cluster state" do
    test "nodeup emits node_joined telemetry with cluster size" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:plugboard, :cluster, :node_joined]
        ])

      pid = Process.whereis(ClusterConnector)

      # Trigger a nodeup
      send(pid, {:nodeup, :"size_test_node@127.0.0.1", []})

      # Verify node_joined telemetry includes cluster_size
      assert_receive {[:plugboard, :cluster, :node_joined], ^ref, %{count: 1},
                      %{node: :"size_test_node@127.0.0.1", cluster_size: _}},
                     1000

      :telemetry.detach(ref)
    end
  end
end
