defmodule Plugboard.TelephoneRegistryTest do
  use ExUnit.Case, async: false

  alias Plugboard.TelephoneRegistry

  # We use async: false because we're testing a singleton GenServer

  setup do
    # Ensure clean state - registry is already started by application
    # We'll use unique path IDs for each test to avoid conflicts
    :ok
  end

  describe "register/2" do
    test "registers a telephone for a path" do
      path_id = Ecto.UUID.generate()
      telephone_pid = spawn(fn -> Process.sleep(:infinity) end)

      assert :ok = TelephoneRegistry.register(path_id, telephone_pid)

      # Verify telephone is registered
      assert {:ok, ^telephone_pid} = TelephoneRegistry.get_telephone(path_id)

      # Cleanup
      Process.exit(telephone_pid, :kill)
      Process.sleep(50)
    end

    test "registers multiple telephones for same path" do
      path_id = Ecto.UUID.generate()
      pid1 = spawn(fn -> Process.sleep(:infinity) end)
      pid2 = spawn(fn -> Process.sleep(:infinity) end)
      pid3 = spawn(fn -> Process.sleep(:infinity) end)

      assert :ok = TelephoneRegistry.register(path_id, pid1)
      assert :ok = TelephoneRegistry.register(path_id, pid2)
      assert :ok = TelephoneRegistry.register(path_id, pid3)

      telephones = TelephoneRegistry.list_telephones(path_id)
      assert length(telephones) == 3
      assert pid1 in telephones
      assert pid2 in telephones
      assert pid3 in telephones

      # Cleanup
      Process.exit(pid1, :kill)
      Process.exit(pid2, :kill)
      Process.exit(pid3, :kill)
      Process.sleep(50)
    end

    test "does not duplicate registration for same telephone" do
      path_id = Ecto.UUID.generate()
      telephone_pid = spawn(fn -> Process.sleep(:infinity) end)

      assert :ok = TelephoneRegistry.register(path_id, telephone_pid)
      assert :ok = TelephoneRegistry.register(path_id, telephone_pid)

      telephones = TelephoneRegistry.list_telephones(path_id)
      assert length(telephones) == 1

      # Cleanup
      Process.exit(telephone_pid, :kill)
      Process.sleep(50)
    end

    test "same telephone can register to multiple paths" do
      path_id1 = Ecto.UUID.generate()
      path_id2 = Ecto.UUID.generate()
      telephone_pid = spawn(fn -> Process.sleep(:infinity) end)

      assert :ok = TelephoneRegistry.register(path_id1, telephone_pid)
      assert :ok = TelephoneRegistry.register(path_id2, telephone_pid)

      assert {:ok, ^telephone_pid} = TelephoneRegistry.get_telephone(path_id1)
      assert {:ok, ^telephone_pid} = TelephoneRegistry.get_telephone(path_id2)

      # Cleanup
      Process.exit(telephone_pid, :kill)
      Process.sleep(50)
    end
  end

  describe "unregister/2" do
    test "unregisters a telephone from a path" do
      path_id = Ecto.UUID.generate()
      telephone_pid = spawn(fn -> Process.sleep(:infinity) end)

      TelephoneRegistry.register(path_id, telephone_pid)
      assert :ok = TelephoneRegistry.unregister(path_id, telephone_pid)

      assert {:error, :no_telephone} = TelephoneRegistry.get_telephone(path_id)

      # Cleanup
      Process.exit(telephone_pid, :kill)
    end

    test "unregistering last telephone removes path entries" do
      path_id = Ecto.UUID.generate()
      telephone_pid = spawn(fn -> Process.sleep(:infinity) end)

      TelephoneRegistry.register(path_id, telephone_pid)
      TelephoneRegistry.unregister(path_id, telephone_pid)

      # Path should not be in active paths
      active_paths = TelephoneRegistry.list_active_paths()
      refute path_id in active_paths

      # Cleanup
      Process.exit(telephone_pid, :kill)
    end

    test "unregistering one of multiple telephones keeps others" do
      path_id = Ecto.UUID.generate()
      pid1 = spawn(fn -> Process.sleep(:infinity) end)
      pid2 = spawn(fn -> Process.sleep(:infinity) end)

      TelephoneRegistry.register(path_id, pid1)
      TelephoneRegistry.register(path_id, pid2)

      assert :ok = TelephoneRegistry.unregister(path_id, pid1)

      telephones = TelephoneRegistry.list_telephones(path_id)
      assert length(telephones) == 1
      assert pid2 in telephones

      # Cleanup
      Process.exit(pid1, :kill)
      Process.exit(pid2, :kill)
      Process.sleep(50)
    end

    test "unregistering non-existent telephone is idempotent" do
      path_id = Ecto.UUID.generate()
      fake_pid = spawn(fn -> Process.sleep(:infinity) end)

      assert :ok = TelephoneRegistry.unregister(path_id, fake_pid)

      # Cleanup
      Process.exit(fake_pid, :kill)
    end
  end

  describe "get_telephone/1 - Round-Robin Load Balancing" do
    test "returns error when no telephone registered" do
      path_id = Ecto.UUID.generate()

      assert {:error, :no_telephone} = TelephoneRegistry.get_telephone(path_id)
    end

    test "returns single telephone when only one registered" do
      path_id = Ecto.UUID.generate()
      telephone_pid = spawn(fn -> Process.sleep(:infinity) end)

      TelephoneRegistry.register(path_id, telephone_pid)

      assert {:ok, ^telephone_pid} = TelephoneRegistry.get_telephone(path_id)

      # Cleanup
      Process.exit(telephone_pid, :kill)
      Process.sleep(50)
    end

    test "round-robin distributes requests across multiple telephones" do
      path_id = Ecto.UUID.generate()
      pid1 = spawn(fn -> Process.sleep(:infinity) end)
      pid2 = spawn(fn -> Process.sleep(:infinity) end)
      pid3 = spawn(fn -> Process.sleep(:infinity) end)

      TelephoneRegistry.register(path_id, pid1)
      TelephoneRegistry.register(path_id, pid2)
      TelephoneRegistry.register(path_id, pid3)

      # Get 12 telephones (4 cycles through 3 telephones)
      results = for _i <- 1..12, do: TelephoneRegistry.get_telephone(path_id)

      # Extract PIDs
      pids = Enum.map(results, fn {:ok, pid} -> pid end)

      # Count occurrences
      pid1_count = Enum.count(pids, &(&1 == pid1))
      pid2_count = Enum.count(pids, &(&1 == pid2))
      pid3_count = Enum.count(pids, &(&1 == pid3))

      # Each should get exactly 4 requests (12 / 3 = 4)
      assert pid1_count == 4
      assert pid2_count == 4
      assert pid3_count == 4

      # Verify round-robin order: should cycle through all three
      assert Enum.at(pids, 0) == Enum.at(pids, 3)
      assert Enum.at(pids, 1) == Enum.at(pids, 4)
      assert Enum.at(pids, 2) == Enum.at(pids, 5)

      # Cleanup
      Process.exit(pid1, :kill)
      Process.exit(pid2, :kill)
      Process.exit(pid3, :kill)
      Process.sleep(50)
    end

    test "round-robin with 2 telephones alternates correctly" do
      path_id = Ecto.UUID.generate()
      pid1 = spawn(fn -> Process.sleep(:infinity) end)
      pid2 = spawn(fn -> Process.sleep(:infinity) end)

      TelephoneRegistry.register(path_id, pid1)
      TelephoneRegistry.register(path_id, pid2)

      # Get 10 telephones
      results = for _i <- 1..10, do: TelephoneRegistry.get_telephone(path_id)
      pids = Enum.map(results, fn {:ok, pid} -> pid end)

      # Should alternate: pid1, pid2, pid1, pid2, ...
      assert Enum.at(pids, 0) == Enum.at(pids, 2)
      assert Enum.at(pids, 1) == Enum.at(pids, 3)

      # Each gets 5 requests
      pid1_count = Enum.count(pids, &(&1 == pid1))
      pid2_count = Enum.count(pids, &(&1 == pid2))
      assert pid1_count == 5
      assert pid2_count == 5

      # Cleanup
      Process.exit(pid1, :kill)
      Process.exit(pid2, :kill)
      Process.sleep(50)
    end

    test "counter wraps at 1 billion to prevent overflow (CRITICAL-1)" do
      path_id = Ecto.UUID.generate()
      pid1 = spawn(fn -> Process.sleep(:infinity) end)

      TelephoneRegistry.register(path_id, pid1)

      # Manually set counter to near overflow
      table_name = :telephone_registry
      :ets.insert(table_name, {{:counter, path_id}, 999_999_998})

      # Get telephone 3 times, counter should wrap
      {:ok, ^pid1} = TelephoneRegistry.get_telephone(path_id)
      {:ok, ^pid1} = TelephoneRegistry.get_telephone(path_id)
      {:ok, ^pid1} = TelephoneRegistry.get_telephone(path_id)

      # Check counter wrapped (should be 0, 1, or 2)
      [{_, counter}] = :ets.lookup(table_name, {:counter, path_id})
      assert counter < 1_000_000_000
      assert counter in [0, 1, 2]

      # Cleanup
      Process.exit(pid1, :kill)
      Process.sleep(50)
    end

    test "counter handles multiple paths independently" do
      path_id1 = Ecto.UUID.generate()
      path_id2 = Ecto.UUID.generate()
      pid1 = spawn(fn -> Process.sleep(:infinity) end)
      pid2 = spawn(fn -> Process.sleep(:infinity) end)

      TelephoneRegistry.register(path_id1, pid1)
      TelephoneRegistry.register(path_id2, pid2)

      # Get from path1 5 times
      for _i <- 1..5, do: TelephoneRegistry.get_telephone(path_id1)

      # Get from path2 3 times
      for _i <- 1..3, do: TelephoneRegistry.get_telephone(path_id2)

      # Check counters are independent
      table_name = :telephone_registry
      [{_, counter1}] = :ets.lookup(table_name, {:counter, path_id1})
      [{_, counter2}] = :ets.lookup(table_name, {:counter, path_id2})

      assert counter1 == 5
      assert counter2 == 3

      # Cleanup
      Process.exit(pid1, :kill)
      Process.exit(pid2, :kill)
      Process.sleep(50)
    end
  end

  describe "list_telephones/1" do
    test "returns empty list for path with no telephones" do
      path_id = Ecto.UUID.generate()

      assert [] = TelephoneRegistry.list_telephones(path_id)
    end

    test "returns all telephones for a path" do
      path_id = Ecto.UUID.generate()
      pid1 = spawn(fn -> Process.sleep(:infinity) end)
      pid2 = spawn(fn -> Process.sleep(:infinity) end)

      TelephoneRegistry.register(path_id, pid1)
      TelephoneRegistry.register(path_id, pid2)

      telephones = TelephoneRegistry.list_telephones(path_id)
      assert length(telephones) == 2
      assert pid1 in telephones
      assert pid2 in telephones

      # Cleanup
      Process.exit(pid1, :kill)
      Process.exit(pid2, :kill)
      Process.sleep(50)
    end
  end

  describe "count_telephones/1" do
    test "returns 0 for path with no telephones" do
      path_id = Ecto.UUID.generate()

      assert 0 = TelephoneRegistry.count_telephones(path_id)
    end

    test "returns correct count for path with telephones" do
      path_id = Ecto.UUID.generate()
      pid1 = spawn(fn -> Process.sleep(:infinity) end)
      pid2 = spawn(fn -> Process.sleep(:infinity) end)
      pid3 = spawn(fn -> Process.sleep(:infinity) end)

      TelephoneRegistry.register(path_id, pid1)
      assert 1 = TelephoneRegistry.count_telephones(path_id)

      TelephoneRegistry.register(path_id, pid2)
      assert 2 = TelephoneRegistry.count_telephones(path_id)

      TelephoneRegistry.register(path_id, pid3)
      assert 3 = TelephoneRegistry.count_telephones(path_id)

      # Cleanup
      Process.exit(pid1, :kill)
      Process.exit(pid2, :kill)
      Process.exit(pid3, :kill)
      Process.sleep(50)
    end
  end

  describe "list_active_paths/0" do
    test "returns empty list when no telephones registered" do
      # Note: May have paths from other tests, so we check for specific path
      path_id = Ecto.UUID.generate()

      active_paths = TelephoneRegistry.list_active_paths()
      refute path_id in active_paths
    end

    test "returns paths with at least one telephone" do
      path_id = Ecto.UUID.generate()
      telephone_pid = spawn(fn -> Process.sleep(:infinity) end)

      TelephoneRegistry.register(path_id, telephone_pid)

      active_paths = TelephoneRegistry.list_active_paths()
      assert path_id in active_paths

      # Cleanup
      Process.exit(telephone_pid, :kill)
      Process.sleep(50)
    end

    test "removes path from active list when all telephones unregistered" do
      path_id = Ecto.UUID.generate()
      telephone_pid = spawn(fn -> Process.sleep(:infinity) end)

      TelephoneRegistry.register(path_id, telephone_pid)
      assert path_id in TelephoneRegistry.list_active_paths()

      TelephoneRegistry.unregister(path_id, telephone_pid)
      refute path_id in TelephoneRegistry.list_active_paths()

      # Cleanup
      Process.exit(telephone_pid, :kill)
    end
  end

  describe "stats/0" do
    test "returns statistics about registry" do
      path_id1 = Ecto.UUID.generate()
      path_id2 = Ecto.UUID.generate()
      pid1 = spawn(fn -> Process.sleep(:infinity) end)
      pid2 = spawn(fn -> Process.sleep(:infinity) end)
      pid3 = spawn(fn -> Process.sleep(:infinity) end)

      # Before registration
      stats_before = TelephoneRegistry.stats()
      active_paths_before = stats_before.active_paths
      total_telephones_before = stats_before.total_telephones

      # Register telephones
      TelephoneRegistry.register(path_id1, pid1)
      TelephoneRegistry.register(path_id1, pid2)
      TelephoneRegistry.register(path_id2, pid3)

      stats_after = TelephoneRegistry.stats()

      # Should have 2 more active paths
      assert stats_after.active_paths == active_paths_before + 2
      # Should have 3 more telephones
      assert stats_after.total_telephones == total_telephones_before + 3

      # Cleanup
      Process.exit(pid1, :kill)
      Process.exit(pid2, :kill)
      Process.exit(pid3, :kill)
      Process.sleep(50)
    end

    test "stats reflect current state" do
      path_id = Ecto.UUID.generate()
      pid1 = spawn(fn -> Process.sleep(:infinity) end)
      pid2 = spawn(fn -> Process.sleep(:infinity) end)

      stats_initial = TelephoneRegistry.stats()

      TelephoneRegistry.register(path_id, pid1)
      stats_one = TelephoneRegistry.stats()

      TelephoneRegistry.register(path_id, pid2)
      stats_two = TelephoneRegistry.stats()

      TelephoneRegistry.unregister(path_id, pid1)
      stats_after_unregister = TelephoneRegistry.stats()

      # Active paths increases by 1 (same path)
      assert stats_one.active_paths == stats_initial.active_paths + 1
      assert stats_two.active_paths == stats_one.active_paths

      # Total telephones increases
      assert stats_one.total_telephones == stats_initial.total_telephones + 1
      assert stats_two.total_telephones == stats_initial.total_telephones + 2
      assert stats_after_unregister.total_telephones == stats_initial.total_telephones + 1

      # Cleanup
      Process.exit(pid1, :kill)
      Process.exit(pid2, :kill)
      Process.sleep(50)
    end
  end

  describe "process monitoring and cleanup" do
    test "automatically removes dead telephone process" do
      path_id = Ecto.UUID.generate()
      telephone_pid = spawn(fn -> Process.sleep(:infinity) end)

      TelephoneRegistry.register(path_id, telephone_pid)
      assert {:ok, ^telephone_pid} = TelephoneRegistry.get_telephone(path_id)

      # Kill the process
      Process.exit(telephone_pid, :kill)

      # Wait for monitor to detect and cleanup
      Process.sleep(100)

      # Telephone should be removed
      assert {:error, :no_telephone} = TelephoneRegistry.get_telephone(path_id)
      assert [] = TelephoneRegistry.list_telephones(path_id)
    end

    test "removes dead telephone from multiple paths" do
      path_id1 = Ecto.UUID.generate()
      path_id2 = Ecto.UUID.generate()
      telephone_pid = spawn(fn -> Process.sleep(:infinity) end)

      TelephoneRegistry.register(path_id1, telephone_pid)
      TelephoneRegistry.register(path_id2, telephone_pid)

      # Kill the process
      Process.exit(telephone_pid, :kill)
      Process.sleep(100)

      # Should be removed from both paths
      assert {:error, :no_telephone} = TelephoneRegistry.get_telephone(path_id1)
      assert {:error, :no_telephone} = TelephoneRegistry.get_telephone(path_id2)
    end

    test "other telephones remain when one dies" do
      path_id = Ecto.UUID.generate()
      pid1 = spawn(fn -> Process.sleep(:infinity) end)
      pid2 = spawn(fn -> Process.sleep(:infinity) end)
      pid3 = spawn(fn -> Process.sleep(:infinity) end)

      TelephoneRegistry.register(path_id, pid1)
      TelephoneRegistry.register(path_id, pid2)
      TelephoneRegistry.register(path_id, pid3)

      # Kill one process
      Process.exit(pid2, :kill)
      Process.sleep(100)

      # Others should remain
      telephones = TelephoneRegistry.list_telephones(path_id)
      assert length(telephones) == 2
      assert pid1 in telephones
      assert pid3 in telephones
      refute pid2 in telephones

      # Cleanup
      Process.exit(pid1, :kill)
      Process.exit(pid3, :kill)
      Process.sleep(50)
    end

    test "cleans up path entries when last telephone dies" do
      path_id = Ecto.UUID.generate()
      telephone_pid = spawn(fn -> Process.sleep(:infinity) end)

      TelephoneRegistry.register(path_id, telephone_pid)
      assert path_id in TelephoneRegistry.list_active_paths()

      # Kill the process
      Process.exit(telephone_pid, :kill)
      Process.sleep(100)

      # Path should be removed from active paths
      refute path_id in TelephoneRegistry.list_active_paths()

      # Counter should be cleaned up (no entry)
      table_name = :telephone_registry
      assert [] = :ets.lookup(table_name, {:counter, path_id})
    end

    test "handles normal exit vs kill" do
      path_id = Ecto.UUID.generate()

      # Normal exit
      pid_normal = spawn(fn -> :ok end)
      TelephoneRegistry.register(path_id, pid_normal)
      Process.sleep(100)

      # Should be cleaned up
      refute pid_normal in TelephoneRegistry.list_telephones(path_id)

      # Kill exit
      pid_kill = spawn(fn -> Process.sleep(:infinity) end)
      TelephoneRegistry.register(path_id, pid_kill)
      Process.exit(pid_kill, :kill)
      Process.sleep(100)

      # Should be cleaned up
      refute pid_kill in TelephoneRegistry.list_telephones(path_id)
    end
  end

  describe "concurrent operations" do
    test "concurrent registrations are safe" do
      path_id = Ecto.UUID.generate()

      # Spawn 10 telephones concurrently
      pids =
        for _i <- 1..10 do
          spawn(fn -> Process.sleep(:infinity) end)
        end

      # Register all concurrently
      tasks =
        for pid <- pids do
          Task.async(fn -> TelephoneRegistry.register(path_id, pid) end)
        end

      Enum.each(tasks, &Task.await/1)

      # All should be registered
      telephones = TelephoneRegistry.list_telephones(path_id)
      assert length(telephones) == 10

      # Cleanup
      Enum.each(pids, &Process.exit(&1, :kill))
      Process.sleep(100)
    end

    test "concurrent get_telephone calls are safe" do
      path_id = Ecto.UUID.generate()
      pid1 = spawn(fn -> Process.sleep(:infinity) end)
      pid2 = spawn(fn -> Process.sleep(:infinity) end)

      TelephoneRegistry.register(path_id, pid1)
      TelephoneRegistry.register(path_id, pid2)

      # Make 100 concurrent get_telephone calls
      tasks =
        for _i <- 1..100 do
          Task.async(fn -> TelephoneRegistry.get_telephone(path_id) end)
        end

      results = Enum.map(tasks, &Task.await/1)

      # All should succeed
      assert Enum.all?(results, fn
               {:ok, _} -> true
               _ -> false
             end)

      # Should have a reasonable distribution (not 100-0)
      pids = Enum.map(results, fn {:ok, pid} -> pid end)
      pid1_count = Enum.count(pids, &(&1 == pid1))
      pid2_count = Enum.count(pids, &(&1 == pid2))

      # Each should get at least 30% of requests (not perfect but reasonable)
      assert pid1_count >= 30
      assert pid2_count >= 30

      # Cleanup
      Process.exit(pid1, :kill)
      Process.exit(pid2, :kill)
      Process.sleep(50)
    end

    test "concurrent register and get_telephone are safe" do
      path_id = Ecto.UUID.generate()
      pids = for _i <- 1..5, do: spawn(fn -> Process.sleep(:infinity) end)

      # Register and get concurrently
      register_tasks =
        for pid <- pids do
          Task.async(fn -> TelephoneRegistry.register(path_id, pid) end)
        end

      get_tasks =
        for _i <- 1..20 do
          Task.async(fn -> TelephoneRegistry.get_telephone(path_id) end)
        end

      Enum.each(register_tasks ++ get_tasks, &Task.await/1)

      # All should be registered eventually
      assert TelephoneRegistry.count_telephones(path_id) == 5

      # Cleanup
      Enum.each(pids, &Process.exit(&1, :kill))
      Process.sleep(100)
    end
  end
end
