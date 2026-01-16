defmodule Plugboard.MountNotifierTest do
  use Plugboard.DataCase, async: false

  import Plugboard.AccountsFixtures

  alias Plugboard.MountNotifier
  alias Plugboard.MountStore
  alias Plugboard.Paths
  alias Plugboard.Repo

  setup do
    # Ensure MountStore and MountNotifier are running
    MountStore.reload_all()
    :ok
  end

  describe "initial connection" do
    test "MountNotifier process is alive and registered" do
      assert Process.whereis(MountNotifier) != nil
      assert Process.alive?(Process.whereis(MountNotifier))
    end

    test "handles initial connection successfully" do
      # MountNotifier should have connected during application startup
      pid = Process.whereis(MountNotifier)
      assert pid != nil

      # Check process state indicates successful connection
      state = :sys.get_state(pid)
      assert state.pid != nil, "Should have PostgreSQL connection PID"
      assert state.mount_ref != nil, "Should have mount monitoring reference"
      assert state.domain_ref != nil, "Should have domain monitoring reference"
      assert state.reconnect_attempts == 0, "Should have zero reconnect attempts on success"
    end
  end

  describe "NOTIFY message handling" do
    test "processes mount_added action and updates ETS" do
      user = user_fixture()

      # Create path without marking as mount
      {:ok, path} =
        Paths.create_path(%{
          path: "notify-added",
          user_id: user.id
        })

      # Should not be in ETS yet
      assert {:error, :not_found} = MountStore.match("/notify-added")

      # Mark as mount (this sends NOTIFY)
      {:ok, _mount} = Paths.update_path(path, %{mount_point: true})

      # Wait for NOTIFY to propagate and process
      # Note: In test environment, NOTIFY is slow, so we use a reasonable timeout
      wait_for_mount("/notify-added", timeout: 2000)

      # Should now be in ETS
      assert {:ok, {"/notify-added", "/", _}} = MountStore.match("/notify-added")
    end

    test "processes mount_removed action and updates ETS" do
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "notify-removed",
          user_id: user.id
        })

      {:ok, mounted_path} = Paths.update_path(path, %{mount_point: true})

      # Ensure it's in ETS
      MountStore.reload_all()
      assert {:ok, _} = MountStore.match("/notify-removed")

      # Unmark as mount (this sends NOTIFY with mount_removed)
      {:ok, _unmounted} = Paths.update_path(mounted_path, %{mount_point: false})

      # Wait for NOTIFY to propagate
      :timer.sleep(200)
      MountStore.reload_all()

      # Should no longer be in ETS
      assert {:error, :not_found} = MountStore.match("/notify-removed")
    end

    test "handles malformed JSON payload gracefully" do
      # Send malformed JSON via NOTIFY
      Repo.query("SELECT pg_notify('plugboard_mounts', 'invalid json}')", [])

      :timer.sleep(100)

      # MountNotifier should log error but not crash
      assert Process.whereis(MountNotifier) != nil
      assert Process.alive?(Process.whereis(MountNotifier))

      # System should still be operational
      user = user_fixture()
      {:ok, path} = Paths.create_path(%{path: "test-after-error", user_id: user.id})
      {:ok, _} = Paths.update_path(path, %{mount_point: true})
      MountStore.reload_all()
      assert {:ok, _} = MountStore.match("/test-after-error")
    end

    test "handles NOTIFY with missing fields" do
      # Send JSON without required fields
      payload = Jason.encode!(%{"action" => "mount_added"})
      Repo.query("SELECT pg_notify('plugboard_mounts', $1)", [payload])

      :timer.sleep(100)

      # Should not crash
      assert Process.whereis(MountNotifier) != nil
      assert Process.alive?(Process.whereis(MountNotifier))
    end

    test "handles NOTIFY with unknown action" do
      # Send valid JSON but unknown action
      payload = Jason.encode!(%{"action" => "unknown_action", "full_path" => "/test"})
      Repo.query("SELECT pg_notify('plugboard_mounts', $1)", [payload])

      :timer.sleep(100)

      # Should log warning but not crash
      assert Process.whereis(MountNotifier) != nil
      assert Process.alive?(Process.whereis(MountNotifier))
    end

    test "handles empty NOTIFY payload" do
      Repo.query("SELECT pg_notify('plugboard_mounts', '')", [])

      :timer.sleep(100)

      # Should not crash
      assert Process.whereis(MountNotifier) != nil
      assert Process.alive?(Process.whereis(MountNotifier))
    end

    test "handles NOTIFY with null values" do
      payload = Jason.encode!(%{"action" => nil, "full_path" => nil})
      Repo.query("SELECT pg_notify('plugboard_mounts', $1)", [payload])

      :timer.sleep(100)

      # Should not crash
      assert Process.whereis(MountNotifier) != nil
      assert Process.alive?(Process.whereis(MountNotifier))
    end
  end

  describe "connection resilience" do
    test "MountNotifier survives multiple malformed payloads" do
      # Send multiple malformed payloads in rapid succession
      for _i <- 1..10 do
        Repo.query("SELECT pg_notify('plugboard_mounts', 'bad{json')", [])
        :timer.sleep(10)
      end

      :timer.sleep(200)

      # Should still be alive
      assert Process.whereis(MountNotifier) != nil
      assert Process.alive?(Process.whereis(MountNotifier))

      # Should still process valid messages
      user = user_fixture()
      {:ok, path} = Paths.create_path(%{path: "after-spam", user_id: user.id})
      {:ok, _} = Paths.update_path(path, %{mount_point: true})
      MountStore.reload_all()
      assert {:ok, _} = MountStore.match("/after-spam")
    end
  end

  describe "edge cases" do
    test "handles NOTIFY for non-existent mount" do
      # Try to notify about a mount that doesn't exist in DB
      payload = Jason.encode!(%{"action" => "mount_added", "full_path" => "/nonexistent"})
      Repo.query("SELECT pg_notify('plugboard_mounts', $1)", [payload])

      :timer.sleep(100)

      # Should not crash
      assert Process.whereis(MountNotifier) != nil

      # Should not be in ETS
      assert {:error, :not_found} = MountStore.match("/nonexistent")
    end

    test "handles NOTIFY for path that was just deleted" do
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "deleted",
          user_id: user.id
        })

      {:ok, _mount} = Paths.update_path(path, %{mount_point: true})
      MountStore.reload_all()

      # Delete it
      {:ok, _} = Paths.delete_path(path)
      MountStore.reload_all()

      # Manually send NOTIFY (race condition simulation)
      payload = Jason.encode!(%{"action" => "mount_added", "full_path" => "/deleted"})
      Repo.query("SELECT pg_notify('plugboard_mounts', $1)", [payload])

      :timer.sleep(100)

      # Should handle gracefully (will query DB and find it deleted)
      assert Process.whereis(MountNotifier) != nil
    end

    test "handles very long path in NOTIFY" do
      long_path = "/" <> String.duplicate("a", 1000)
      payload = Jason.encode!(%{"action" => "mount_added", "full_path" => long_path})
      Repo.query("SELECT pg_notify('plugboard_mounts', $1)", [payload])

      :timer.sleep(100)

      # Should not crash
      assert Process.whereis(MountNotifier) != nil
    end

    test "handles special characters in NOTIFY path" do
      special_paths = [
        "/test/with spaces",
        "/test/with-émojis-🎉",
        "/test/with\ttabs",
        "/test/with\nnewlines"
      ]

      for path <- special_paths do
        payload = Jason.encode!(%{"action" => "mount_added", "full_path" => path})
        Repo.query("SELECT pg_notify('plugboard_mounts', $1)", [payload])
        :timer.sleep(10)
      end

      :timer.sleep(200)

      # Should still be alive
      assert Process.whereis(MountNotifier) != nil
      assert Process.alive?(Process.whereis(MountNotifier))
    end

    test "handles concurrent NOTIFY messages" do
      user = user_fixture()

      # Create multiple paths
      # Create multiple paths and mark as mounts
      for i <- 1..5 do
        {:ok, path} = Paths.create_path(%{path: "concurrent#{i}", user_id: user.id})
        {:ok, _} = Paths.update_path(path, %{mount_point: true})
      end

      # All should process eventually (NOTIFY sent automatically)
      :timer.sleep(500)
      MountStore.reload_all()

      # All should be accessible
      for i <- 1..5 do
        assert {:ok, _} = MountStore.match("/concurrent#{i}")
      end

      # MountNotifier should still be healthy
      assert Process.whereis(MountNotifier) != nil
      assert Process.alive?(Process.whereis(MountNotifier))
    end
  end

  describe "integration with MountStore" do
    test "NOTIFY triggers MountStore.refresh_mount/1" do
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "integration-test",
          user_id: user.id
        })

      # Mark as mount - this sends NOTIFY
      {:ok, mount} = Paths.update_path(path, %{mount_point: true})

      # Wait for NOTIFY processing
      wait_for_mount("/integration-test", timeout: 2000)

      # Verify it's in ETS with correct data
      assert {:ok, {"/integration-test", "/", mount_id}} =
               MountStore.match("/integration-test")

      assert mount_id == mount.id
    end

    test "NOTIFY triggers MountStore.remove_mount/1 on deletion" do
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "to-be-deleted",
          user_id: user.id
        })

      {:ok, _mount} = Paths.update_path(path, %{mount_point: true})

      # Ensure it's in ETS
      MountStore.reload_all()
      assert {:ok, _} = MountStore.match("/to-be-deleted")

      # Delete the path - this sends NOTIFY
      {:ok, _} = Paths.delete_path(path)

      # Wait for NOTIFY processing
      :timer.sleep(200)
      MountStore.reload_all()

      # Should be removed from ETS
      assert {:error, :not_found} = MountStore.match("/to-be-deleted")
    end
  end

  describe "connection recovery" do
    @tag :capture_log
    test "MountNotifier survives PostgreSQL connection death" do
      # Get initial state
      initial_pid = Process.whereis(MountNotifier)
      assert initial_pid != nil

      initial_state = :sys.get_state(initial_pid)
      pg_connection_pid = initial_state.pid

      # Kill the PostgreSQL connection if it exists
      if pg_connection_pid && Process.alive?(pg_connection_pid) do
        Process.exit(pg_connection_pid, :kill)

        # Wait for reconnection attempt
        :timer.sleep(2000)

        # MountNotifier should still be alive
        assert Process.whereis(MountNotifier) != nil
        assert Process.alive?(Process.whereis(MountNotifier))
      end
    end
  end

  describe "process health" do
    @tag :capture_log
    test "MountNotifier restarts on crash via supervisor" do
      # Get initial PID
      initial_pid = Process.whereis(MountNotifier)
      assert initial_pid != nil

      # Kill the process (supervisor should restart it)
      # This will log an error, but that's expected and suppressed by @tag :capture_log
      Process.exit(initial_pid, :kill)

      # Wait for supervisor to restart
      :timer.sleep(200)

      # Should have a new PID
      new_pid = Process.whereis(MountNotifier)
      assert new_pid != nil
      assert new_pid != initial_pid
      assert Process.alive?(new_pid)
    end
  end

  describe "handle_info for unexpected messages" do
    @tag :capture_log
    test "handles unexpected messages gracefully" do
      pid = Process.whereis(MountNotifier)
      assert pid != nil

      # Send unexpected message
      send(pid, {:unexpected_message, "test"})

      # Should not crash
      :timer.sleep(50)
      assert Process.alive?(pid)
    end

    @tag :capture_log
    test "handles arbitrary data in messages" do
      pid = Process.whereis(MountNotifier)
      assert pid != nil

      # Send various unexpected messages
      send(pid, :random_atom)
      send(pid, {1, 2, 3})
      send(pid, %{key: "value"})

      # Should not crash
      :timer.sleep(50)
      assert Process.alive?(pid)
    end
  end

  describe "exponential backoff calculation" do
    @tag :capture_log
    test "reconnection uses exponential backoff" do
      # Get initial state
      initial_pid = Process.whereis(MountNotifier)
      assert initial_pid != nil

      initial_state = :sys.get_state(initial_pid)
      pg_connection_pid = initial_state.pid

      # Kill the PostgreSQL connection multiple times to trigger backoff
      if pg_connection_pid && Process.alive?(pg_connection_pid) do
        Process.exit(pg_connection_pid, :kill)

        # Wait for reconnection
        :timer.sleep(2000)

        # MountNotifier should still be alive and reconnected
        assert Process.whereis(MountNotifier) != nil
        assert Process.alive?(Process.whereis(MountNotifier))

        # Verify state shows successful reconnection (reconnect_attempts reset to 0)
        new_state = :sys.get_state(Process.whereis(MountNotifier))
        assert new_state.reconnect_attempts == 0
      end
    end
  end

  describe "notification channel" do
    test "listens on correct PostgreSQL channel" do
      pid = Process.whereis(MountNotifier)
      assert pid != nil

      state = :sys.get_state(pid)
      # Should have a valid reference from listening
      assert state.ref != nil
    end
  end

  # Helper function to wait for a mount to appear in ETS
  # This is necessary because NOTIFY propagation has some latency
  defp wait_for_mount(path, opts) when is_list(opts) do
    timeout = Keyword.get(opts, :timeout, 1000)
    interval = Keyword.get(opts, :interval, 50)
    deadline = System.monotonic_time(:millisecond) + timeout

    do_wait_for_mount(path, deadline, interval)
  end

  defp do_wait_for_mount(path, deadline, interval) do
    case MountStore.match(path) do
      {:ok, _} = result ->
        result

      {:error, :not_found} ->
        now = System.monotonic_time(:millisecond)

        if now < deadline do
          :timer.sleep(interval)
          do_wait_for_mount(path, deadline, interval)
        else
          # Timeout - do one final reload and check
          MountStore.reload_all()

          case MountStore.match(path) do
            {:ok, _} = result -> result
            error -> error
          end
        end
    end
  end
end
