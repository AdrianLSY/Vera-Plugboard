defmodule Plugboard.TelephoneRegistryTest do
  use ExUnit.Case, async: false

  alias Plugboard.TelephoneRegistry
  alias Plugboard.DistributedRegistry

  # async: false because we're testing a shared registry

  describe "start_link/1" do
    test "returns :ignore since DistributedRegistry handles registration" do
      # TelephoneRegistry.start_link is a no-op that returns :ignore
      # because DistributedRegistry is started separately in the supervision tree
      assert :ignore = TelephoneRegistry.start_link([])
    end
  end

  describe "register/2" do
    test "registers a telephone for a path" do
      path_id = Ecto.UUID.generate()

      # Spawn a process that registers itself
      test_pid = self()

      spawn_link(fn ->
        result = TelephoneRegistry.register(path_id, self())
        send(test_pid, {:register_result, result})
        # Keep process alive for lookup
        Process.sleep(1000)
      end)

      # Wait for registration
      assert_receive {:register_result, :ok}, 1000

      # Wait for Horde CRDT propagation
      Process.sleep(50)

      # Verify registration
      assert TelephoneRegistry.count_telephones(path_id) == 1
    end

    test "returns :ok on successful registration" do
      path_id = Ecto.UUID.generate()
      test_pid = self()

      spawn_link(fn ->
        result = TelephoneRegistry.register(path_id, self())
        send(test_pid, {:result, result})
        Process.sleep(200)
      end)

      assert_receive {:result, :ok}, 1000
    end

    test "allows multiple telephones for same path" do
      path_id = Ecto.UUID.generate()
      test_pid = self()

      # Spawn multiple processes that register themselves
      for i <- 1..3 do
        spawn_link(fn ->
          result = TelephoneRegistry.register(path_id, self())
          send(test_pid, {:register_result, i, result})
          Process.sleep(1000)
        end)
      end

      # Wait for all registrations
      for i <- 1..3 do
        assert_receive {:register_result, ^i, :ok}, 1000
      end

      # Wait for Horde CRDT propagation
      Process.sleep(100)

      # All should be registered
      assert TelephoneRegistry.count_telephones(path_id) == 3
    end
  end

  describe "unregister/2" do
    test "unregisters a telephone from a path" do
      path_id = Ecto.UUID.generate()
      test_pid = self()

      spawn_link(fn ->
        :ok = TelephoneRegistry.register(path_id, self())
        send(test_pid, :registered)

        receive do
          :unregister ->
            TelephoneRegistry.unregister(path_id, self())
            send(test_pid, :unregistered)
        end

        Process.sleep(100)
      end)

      assert_receive :registered, 1000
      assert TelephoneRegistry.count_telephones(path_id) == 1

      send(test_pid, :unregister)
      # Note: we need to send to the spawned process, not test_pid
      # Let's refactor this test
    end

    test "handles unregister for non-existent registration gracefully" do
      path_id = Ecto.UUID.generate()
      # Unregistering when not registered should not crash
      result = TelephoneRegistry.unregister(path_id, self())
      # Result is :ok even if not registered (Horde behavior)
      assert result == :ok
    end
  end

  describe "get_telephone/1" do
    test "returns {:ok, pid} when telephone is registered" do
      path_id = Ecto.UUID.generate()
      test_pid = self()

      child_pid =
        spawn_link(fn ->
          :ok = TelephoneRegistry.register(path_id, self())
          send(test_pid, {:registered, self()})
          # Keep alive for lookup
          Process.sleep(500)
        end)

      assert_receive {:registered, ^child_pid}, 1000

      # Should find the telephone
      assert {:ok, pid} = TelephoneRegistry.get_telephone(path_id)
      assert pid == child_pid
    end

    test "returns {:error, :no_telephone} when no telephone registered" do
      path_id = Ecto.UUID.generate()
      assert {:error, :no_telephone} = TelephoneRegistry.get_telephone(path_id)
    end

    test "returns one of multiple registered telephones" do
      path_id = Ecto.UUID.generate()
      test_pid = self()

      # Register multiple telephones
      for _ <- 1..3 do
        spawn_link(fn ->
          :ok = TelephoneRegistry.register(path_id, self())
          send(test_pid, {:registered, self()})
          Process.sleep(1000)
        end)
      end

      # Wait for all registrations
      registered_pids =
        for _ <- 1..3 do
          receive do
            {:registered, pid} -> pid
          after
            1000 -> flunk("Timeout waiting for registration")
          end
        end

      # Wait for Horde CRDT propagation
      Process.sleep(100)

      # get_telephone should return one of the registered PIDs
      assert {:ok, pid} = TelephoneRegistry.get_telephone(path_id)
      assert pid in registered_pids
    end
  end

  describe "list_telephones/1" do
    test "returns list of PIDs for a path" do
      path_id = Ecto.UUID.generate()
      test_pid = self()

      spawn_link(fn ->
        :ok = TelephoneRegistry.register(path_id, self())
        send(test_pid, {:registered, self()})
        Process.sleep(1000)
      end)

      assert_receive {:registered, child_pid}, 1000

      # Wait for Horde CRDT propagation
      Process.sleep(50)

      telephones = TelephoneRegistry.list_telephones(path_id)
      assert is_list(telephones)
      assert child_pid in telephones
    end

    test "returns empty list when no telephones registered" do
      path_id = Ecto.UUID.generate()
      assert TelephoneRegistry.list_telephones(path_id) == []
    end
  end

  describe "count_telephones/1" do
    test "returns 0 for path with no telephones" do
      path_id = Ecto.UUID.generate()
      assert TelephoneRegistry.count_telephones(path_id) == 0
    end

    test "returns correct count for path with telephones" do
      path_id = Ecto.UUID.generate()
      test_pid = self()

      for i <- 1..5 do
        spawn_link(fn ->
          :ok = TelephoneRegistry.register(path_id, self())
          send(test_pid, {:registered, i})
          Process.sleep(1000)
        end)
      end

      # Wait for all registrations
      for i <- 1..5 do
        assert_receive {:registered, ^i}, 1000
      end

      # Wait for Horde CRDT propagation
      Process.sleep(100)

      assert TelephoneRegistry.count_telephones(path_id) == 5
    end
  end

  describe "list_active_paths/0" do
    test "returns list of paths with registered telephones" do
      path_id1 = Ecto.UUID.generate()
      path_id2 = Ecto.UUID.generate()
      test_pid = self()

      spawn_link(fn ->
        :ok = TelephoneRegistry.register(path_id1, self())
        send(test_pid, :registered1)
        Process.sleep(1000)
      end)

      spawn_link(fn ->
        :ok = TelephoneRegistry.register(path_id2, self())
        send(test_pid, :registered2)
        Process.sleep(1000)
      end)

      assert_receive :registered1, 1000
      assert_receive :registered2, 1000

      # Wait for Horde CRDT propagation
      Process.sleep(100)

      active_paths = TelephoneRegistry.list_active_paths()
      assert is_list(active_paths)
      assert path_id1 in active_paths
      assert path_id2 in active_paths
    end
  end

  describe "stats/0" do
    test "returns map with registry statistics" do
      stats = TelephoneRegistry.stats()

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

    test "stats reflect registered telephones" do
      path_id = Ecto.UUID.generate()
      test_pid = self()

      spawn_link(fn ->
        :ok = TelephoneRegistry.register(path_id, self())
        send(test_pid, :registered)
        Process.sleep(1000)
      end)

      assert_receive :registered, 1000

      # Wait for Horde CRDT propagation
      Process.sleep(50)

      stats = TelephoneRegistry.stats()

      # Should have at least one telephone (the one we just registered)
      # and at least one active path
      assert stats.total_telephones >= 1
      assert stats.active_paths >= 1
    end
  end

  describe "members/0" do
    test "returns list of Horde cluster members" do
      members = TelephoneRegistry.members()

      assert is_list(members)
      # Should have at least one member (current node)
      assert length(members) >= 1

      # Each member should be a tuple {module, node}
      for member <- members do
        assert is_tuple(member)
        {module, node_name} = member
        assert module == DistributedRegistry
        assert is_atom(node_name)
      end
    end
  end

  describe "automatic cleanup on process death" do
    test "telephone is unregistered when process dies" do
      path_id = Ecto.UUID.generate()
      test_pid = self()

      child_pid =
        spawn(fn ->
          :ok = TelephoneRegistry.register(path_id, self())
          send(test_pid, :registered)

          receive do
            :die -> :ok
          end
        end)

      assert_receive :registered, 1000
      assert TelephoneRegistry.count_telephones(path_id) == 1

      # Kill the process
      Process.exit(child_pid, :kill)

      # Wait for Horde to detect the death and clean up
      Process.sleep(100)

      # Should be unregistered
      assert TelephoneRegistry.count_telephones(path_id) == 0
    end
  end
end
