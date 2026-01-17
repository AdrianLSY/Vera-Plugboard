defmodule Plugboard.DistributedRegistryTest do
  use ExUnit.Case, async: false

  alias Plugboard.DistributedRegistry

  # async: false because we're testing a distributed system with shared state

  describe "register/1 - behavior tests" do
    test "calling process can register itself for a path" do
      path_id = Ecto.UUID.generate()

      # The calling process (this test) registers itself
      assert {:ok, pid} = DistributedRegistry.register(path_id)
      assert pid == self()

      # Cleanup
      DistributedRegistry.unregister(path_id)
    end

    test "process can register for multiple paths" do
      path_id1 = Ecto.UUID.generate()
      path_id2 = Ecto.UUID.generate()

      assert {:ok, _} = DistributedRegistry.register(path_id1)
      assert {:ok, _} = DistributedRegistry.register(path_id2)

      # Give Horde a moment to sync CRDT state
      Process.sleep(50)

      # Both registrations should exist
      assert {:ok, _} = DistributedRegistry.get_telephone(path_id1)
      assert {:ok, _} = DistributedRegistry.get_telephone(path_id2)

      # Cleanup
      DistributedRegistry.unregister(path_id1)
      DistributedRegistry.unregister(path_id2)
    end

    test "duplicate registration is idempotent" do
      path_id = Ecto.UUID.generate()

      assert {:ok, pid1} = DistributedRegistry.register(path_id)
      assert {:ok, pid2} = DistributedRegistry.register(path_id)
      assert pid1 == pid2

      # Only one registration should exist
      telephones = DistributedRegistry.lookup(path_id)
      assert length(telephones) == 1

      # Cleanup
      DistributedRegistry.unregister(path_id)
    end
  end

  describe "unregister/1 - behavior tests" do
    test "calling process can unregister itself" do
      path_id = Ecto.UUID.generate()

      DistributedRegistry.register(path_id)
      assert :ok = DistributedRegistry.unregister(path_id)

      # Verify unregistered
      assert {:error, :no_telephone} = DistributedRegistry.get_telephone(path_id)
    end

    test "unregistering non-existent registration is safe" do
      path_id = Ecto.UUID.generate()

      # This should not crash
      assert :ok = DistributedRegistry.unregister(path_id)
    end
  end

  describe "get_telephone/1 - behavior tests" do
    test "returns error when no telephone is registered" do
      path_id = Ecto.UUID.generate()

      assert {:error, :no_telephone} = DistributedRegistry.get_telephone(path_id)
    end

    test "returns a registered telephone" do
      path_id = Ecto.UUID.generate()
      DistributedRegistry.register(path_id)

      # Wait for Horde CRDT propagation
      Process.sleep(50)

      assert {:ok, pid} = DistributedRegistry.get_telephone(path_id)
      assert is_pid(pid)

      # Cleanup
      DistributedRegistry.unregister(path_id)
    end

    test "returns one of multiple registered telephones" do
      path_id = Ecto.UUID.generate()

      # Spawn multiple processes that register themselves
      pids = spawn_and_register_multiple(path_id, 3)

      # Should return one of them
      assert {:ok, returned_pid} = DistributedRegistry.get_telephone(path_id)
      assert returned_pid in pids

      # Cleanup
      Enum.each(pids, &Process.exit(&1, :kill))
      :timer.sleep(100)
    end
  end

  describe "lookup/1 - behavior tests" do
    test "returns empty list when no telephones registered" do
      path_id = Ecto.UUID.generate()

      assert [] = DistributedRegistry.lookup(path_id)
    end

    test "returns list of all registered telephones" do
      path_id = Ecto.UUID.generate()

      # Spawn and register 3 processes
      pids = spawn_and_register_multiple(path_id, 3)

      # Lookup should return all 3
      results = DistributedRegistry.lookup(path_id)
      assert length(results) == 3

      returned_pids = Enum.map(results, fn {pid, _value} -> pid end)
      assert Enum.sort(pids) == Enum.sort(returned_pids)

      # Cleanup
      Enum.each(pids, &Process.exit(&1, :kill))
      :timer.sleep(100)
    end
  end

  describe "count_telephones/1 - behavior tests" do
    test "returns 0 when no telephones registered" do
      path_id = Ecto.UUID.generate()

      assert 0 = DistributedRegistry.count_telephones(path_id)
    end

    test "returns correct count of registered telephones" do
      path_id = Ecto.UUID.generate()

      pids = spawn_and_register_multiple(path_id, 5)
      assert 5 = DistributedRegistry.count_telephones(path_id)

      # Cleanup
      Enum.each(pids, &Process.exit(&1, :kill))
      :timer.sleep(100)
    end
  end

  describe "list_active_paths/0 - behavior tests" do
    test "returns list of paths with registered telephones" do
      path_id1 = Ecto.UUID.generate()
      path_id2 = Ecto.UUID.generate()

      # Register on both paths
      pids1 = spawn_and_register_multiple(path_id1, 2)
      pids2 = spawn_and_register_multiple(path_id2, 2)

      active_paths = DistributedRegistry.list_active_paths()

      assert path_id1 in active_paths
      assert path_id2 in active_paths

      # Cleanup
      Enum.each(pids1 ++ pids2, &Process.exit(&1, :kill))
      :timer.sleep(100)
    end
  end

  describe "stats/0 - behavior tests" do
    test "returns statistics about the registry" do
      stats = DistributedRegistry.stats()

      assert is_map(stats)
      assert Map.has_key?(stats, :active_paths)
      assert Map.has_key?(stats, :total_telephones)
      assert Map.has_key?(stats, :nodes)
      assert Map.has_key?(stats, :this_node)

      assert is_integer(stats.active_paths)
      assert is_integer(stats.total_telephones)
      assert is_integer(stats.nodes)
      assert is_atom(stats.this_node)
    end
  end

  describe "members/0 - behavior tests" do
    test "returns list of Horde cluster members" do
      members = DistributedRegistry.members()

      assert is_list(members)
      assert length(members) >= 1

      # Should include this node
      assert {DistributedRegistry, node()} in members
    end
  end

  ## Helper Functions

  # Spawns multiple processes that register themselves for a path.
  #
  # This helper follows Horde's constraint that processes must register themselves.
  # Each spawned process registers itself and then waits indefinitely.
  defp spawn_and_register_multiple(path_id, count) do
    parent = self()

    pids =
      Enum.map(1..count, fn index ->
        spawn(fn ->
          # Add small delay to prevent registration race conditions
          Process.sleep(index * 10)

          # This process registers itself
          case DistributedRegistry.register(path_id) do
            {:ok, _} ->
              # Signal parent that registration is complete
              send(parent, {:registered, self()})

            {:error, reason} ->
              # Signal parent about failure
              send(parent, {:registration_failed, self(), reason})
          end

          # Wait indefinitely (will be killed by test cleanup)
          Process.sleep(:infinity)
        end)
      end)

    # Wait for all processes to register
    Enum.each(pids, fn pid ->
      receive do
        {:registered, ^pid} ->
          :ok

        {:registration_failed, ^pid, reason} ->
          raise "Process #{inspect(pid)} failed to register: #{inspect(reason)}"
      after
        5000 -> raise "Process #{inspect(pid)} failed to register within 5 seconds"
      end
    end)

    # Give Horde a moment to sync CRDT state
    Process.sleep(50)

    pids
  end
end
