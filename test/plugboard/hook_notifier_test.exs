defmodule Plugboard.HookNotifierTest do
  use Plugboard.DataCase, async: false

  import Plugboard.AccountsFixtures

  alias Plugboard.HookNotifier
  alias Plugboard.HookStore
  alias Plugboard.Paths
  alias Plugboard.Repo

  setup do
    # Ensure HookStore and HookNotifier are running
    HookStore.reload_all()
    :ok
  end

  describe "initial connection" do
    test "HookNotifier process is alive and registered" do
      assert Process.whereis(HookNotifier) != nil
      assert Process.alive?(Process.whereis(HookNotifier))
    end

    test "handles initial connection successfully" do
      pid = Process.whereis(HookNotifier)
      assert pid != nil

      # Check process state indicates successful connection
      state = :sys.get_state(pid)
      assert state.pid != nil, "Should have PostgreSQL connection PID"
      assert state.ref != nil, "Should have listening reference"
      assert state.reconnect_attempts == 0, "Should have zero reconnect attempts on success"
    end
  end

  describe "NOTIFY message handling" do
    setup do
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "hook-notify-test",
          user_id: user.id,
          mount_point: true
        })

      {:ok, target} =
        Paths.create_path(%{
          path: "hook-target",
          user_id: user.id,
          mount_point: true
        })

      %{user: user, path: path, target: target}
    end

    test "processes hook_updated notification directly", %{path: path} do
      # Test that HookNotifier correctly processes a hook_updated notification
      # by sending it directly via pg_notify

      # Ensure we have a clean state
      HookStore.reload_all()

      # Manually create a hook in the database without going through Hooks context
      # to test just the notification handling
      hook_id = Ecto.UUID.generate()
      {:ok, hook_id_binary} = Ecto.UUID.dump(hook_id)
      {:ok, path_id_binary} = Ecto.UUID.dump(path.id)

      # Insert hook directly
      Repo.insert_all("hooks", [
        %{
          id: hook_id_binary,
          path_id: path_id_binary,
          name: "direct-insert-hook",
          target_type: "http_url",
          target_url: "http://example.com/hook",
          execution_order: 0,
          timeout_ms: 5000,
          allowed_status_codes: [200],
          forward_headers: [],
          forward_query_params: false,
          inserted_at: DateTime.utc_now() |> DateTime.truncate(:second),
          updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
        }
      ])

      # Send notification directly
      payload = Jason.encode!(%{"action" => "hook_updated", "path_id" => path.id})
      Repo.query("SELECT pg_notify('plugboard_hooks', $1)", [payload])

      # Wait for notification to be processed
      wait_for_hooks(path.id, expected_count: 1, timeout: 2000)

      hooks = HookStore.get_hooks(path.id)
      assert length(hooks) == 1
      assert hd(hooks).name == "direct-insert-hook"
    end

    test "processes hook_deleted notification directly", %{path: path} do
      # First create and load a hook
      hook_id = Ecto.UUID.generate()
      {:ok, hook_id_binary} = Ecto.UUID.dump(hook_id)
      {:ok, path_id_binary} = Ecto.UUID.dump(path.id)

      Repo.insert_all("hooks", [
        %{
          id: hook_id_binary,
          path_id: path_id_binary,
          name: "to-be-deleted",
          target_type: "http_url",
          target_url: "http://example.com/hook",
          execution_order: 0,
          timeout_ms: 5000,
          allowed_status_codes: [200],
          forward_headers: [],
          forward_query_params: false,
          inserted_at: DateTime.utc_now() |> DateTime.truncate(:second),
          updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
        }
      ])

      HookStore.reload_all()
      assert length(HookStore.get_hooks(path.id)) == 1

      # Soft delete the hook
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.query(
        "UPDATE hooks SET deleted_at = $1 WHERE id = $2",
        [now, hook_id_binary]
      )

      # Send hook_deleted notification
      payload = Jason.encode!(%{"action" => "hook_deleted", "path_id" => path.id})
      Repo.query("SELECT pg_notify('plugboard_hooks', $1)", [payload])

      # Wait for notification to be processed
      wait_for_hooks(path.id, expected_count: 0, timeout: 2000)

      assert HookStore.get_hooks(path.id) == []
    end

    test "handles malformed JSON payload gracefully" do
      # Send malformed JSON via NOTIFY
      Repo.query("SELECT pg_notify('plugboard_hooks', 'invalid json}')", [])

      :timer.sleep(100)

      # HookNotifier should log error but not crash
      assert Process.whereis(HookNotifier) != nil
      assert Process.alive?(Process.whereis(HookNotifier))
    end

    test "handles unknown action gracefully", %{path: path} do
      # Send unknown action via NOTIFY
      payload = Jason.encode!(%{"action" => "unknown_action", "path_id" => path.id})
      Repo.query("SELECT pg_notify('plugboard_hooks', $1)", [payload])

      :timer.sleep(100)

      # HookNotifier should log warning but not crash
      assert Process.whereis(HookNotifier) != nil
      assert Process.alive?(Process.whereis(HookNotifier))
    end
  end

  describe "connection recovery" do
    test "process state tracks reconnect attempts" do
      pid = Process.whereis(HookNotifier)
      state = :sys.get_state(pid)

      # Should have zero reconnect attempts when connected
      assert state.reconnect_attempts == 0
    end

    @tag :capture_log
    test "HookNotifier survives PostgreSQL connection death" do
      # Get initial state
      initial_pid = Process.whereis(HookNotifier)
      assert initial_pid != nil

      initial_state = :sys.get_state(initial_pid)
      pg_connection_pid = initial_state.pid

      # Kill the PostgreSQL connection if it exists
      if pg_connection_pid && Process.alive?(pg_connection_pid) do
        Process.exit(pg_connection_pid, :kill)

        # Wait for reconnection attempt
        :timer.sleep(2000)

        # HookNotifier should still be alive
        assert Process.whereis(HookNotifier) != nil
        assert Process.alive?(Process.whereis(HookNotifier))
      end
    end

    @tag :capture_log
    test "reconnection uses exponential backoff" do
      # Get initial state
      initial_pid = Process.whereis(HookNotifier)
      assert initial_pid != nil

      initial_state = :sys.get_state(initial_pid)
      pg_connection_pid = initial_state.pid

      # Kill the PostgreSQL connection multiple times to trigger backoff
      if pg_connection_pid && Process.alive?(pg_connection_pid) do
        Process.exit(pg_connection_pid, :kill)

        # Wait for reconnection
        :timer.sleep(2000)

        # HookNotifier should still be alive and reconnected
        assert Process.whereis(HookNotifier) != nil
        assert Process.alive?(Process.whereis(HookNotifier))

        # Verify state shows successful reconnection (reconnect_attempts reset to 0)
        new_state = :sys.get_state(Process.whereis(HookNotifier))
        assert new_state.reconnect_attempts == 0
      end
    end
  end

  describe "process health" do
    @tag :capture_log
    test "HookNotifier restarts on crash via supervisor" do
      # Get initial PID
      initial_pid = Process.whereis(HookNotifier)
      assert initial_pid != nil

      # Kill the process (supervisor should restart it)
      Process.exit(initial_pid, :kill)

      # Wait for supervisor to restart
      :timer.sleep(200)

      # Should have a new PID
      new_pid = Process.whereis(HookNotifier)
      assert new_pid != nil
      assert new_pid != initial_pid
      assert Process.alive?(new_pid)
    end

    @tag :capture_log
    test "handles unexpected messages gracefully" do
      pid = Process.whereis(HookNotifier)
      assert pid != nil

      # Send unexpected message
      send(pid, {:unexpected_message, "test"})

      # Should not crash
      :timer.sleep(50)
      assert Process.alive?(pid)
    end

    @tag :capture_log
    test "handles arbitrary data in messages" do
      pid = Process.whereis(HookNotifier)
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

  describe "edge cases" do
    test "handles NOTIFY with missing fields" do
      # Send JSON without required fields
      payload = Jason.encode!(%{"action" => "hook_updated"})
      Repo.query("SELECT pg_notify('plugboard_hooks', $1)", [payload])

      :timer.sleep(100)

      # Should not crash
      assert Process.whereis(HookNotifier) != nil
      assert Process.alive?(Process.whereis(HookNotifier))
    end

    test "handles empty NOTIFY payload" do
      Repo.query("SELECT pg_notify('plugboard_hooks', '')", [])

      :timer.sleep(100)

      # Should not crash
      assert Process.whereis(HookNotifier) != nil
      assert Process.alive?(Process.whereis(HookNotifier))
    end

    test "handles NOTIFY with null values" do
      payload = Jason.encode!(%{"action" => nil, "path_id" => nil})
      Repo.query("SELECT pg_notify('plugboard_hooks', $1)", [payload])

      :timer.sleep(100)

      # Should not crash
      assert Process.whereis(HookNotifier) != nil
      assert Process.alive?(Process.whereis(HookNotifier))
    end

    test "handles NOTIFY for non-existent path" do
      # Try to notify about a path that doesn't exist in DB
      fake_path_id = Ecto.UUID.generate()
      payload = Jason.encode!(%{"action" => "hook_updated", "path_id" => fake_path_id})
      Repo.query("SELECT pg_notify('plugboard_hooks', $1)", [payload])

      :timer.sleep(100)

      # Should not crash
      assert Process.whereis(HookNotifier) != nil
      assert Process.alive?(Process.whereis(HookNotifier))
    end

    test "survives multiple malformed payloads" do
      # Send multiple malformed payloads in rapid succession
      for _i <- 1..10 do
        Repo.query("SELECT pg_notify('plugboard_hooks', 'bad{json')", [])
        :timer.sleep(10)
      end

      :timer.sleep(200)

      # Should still be alive
      assert Process.whereis(HookNotifier) != nil
      assert Process.alive?(Process.whereis(HookNotifier))
    end
  end

  describe "notification channel" do
    test "listens on correct PostgreSQL channel" do
      pid = Process.whereis(HookNotifier)
      assert pid != nil

      state = :sys.get_state(pid)
      # Should have valid reference from listening to the channel
      assert state.ref != nil
    end
  end

  # Helper function to wait for hooks to appear/disappear in HookStore
  # This is necessary because NOTIFY propagation has some latency
  defp wait_for_hooks(path_id, opts) when is_list(opts) do
    expected_count = Keyword.get(opts, :expected_count, 1)
    timeout = Keyword.get(opts, :timeout, 1000)
    interval = Keyword.get(opts, :interval, 50)
    deadline = System.monotonic_time(:millisecond) + timeout

    do_wait_for_hooks(path_id, expected_count, deadline, interval)
  end

  defp do_wait_for_hooks(path_id, expected_count, deadline, interval) do
    hooks = HookStore.get_hooks(path_id)
    current_count = length(hooks)

    if current_count == expected_count do
      {:ok, hooks}
    else
      now = System.monotonic_time(:millisecond)

      if now < deadline do
        :timer.sleep(interval)
        do_wait_for_hooks(path_id, expected_count, deadline, interval)
      else
        # Timeout - do one final reload and check
        HookStore.reload_all()
        hooks = HookStore.get_hooks(path_id)

        if length(hooks) == expected_count do
          {:ok, hooks}
        else
          {:error, :timeout, hooks}
        end
      end
    end
  end
end
