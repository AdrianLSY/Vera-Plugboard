defmodule Plugboard.AsyncHelpers do
  @moduledoc """
  Helpers for testing asynchronous operations like NOTIFY/LISTEN.

  These helpers provide better test reliability by polling for expected
  conditions with timeouts, rather than using arbitrary sleeps.
  """

  @doc """
  Polls a condition function until it returns true or timeout is reached.

  ## Options

  - `:timeout` - Maximum time to wait in milliseconds (default: 5000)
  - `:interval` - Polling interval in milliseconds (default: 10)

  ## Examples

      # Wait for ETS table to be updated
      assert_eventually(fn ->
        :ets.info(:plugboard_mounts, :size) > 0
      end, timeout: 1000)

      # Wait for specific mount to appear
      assert_eventually(fn ->
        match?({:ok, _}, MountStore.match("/api"))
      end)
  """
  def assert_eventually(condition_fn, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5000)
    interval = Keyword.get(opts, :interval, 10)
    deadline = System.monotonic_time(:millisecond) + timeout

    do_assert_eventually(condition_fn, deadline, interval)
  end

  defp do_assert_eventually(condition_fn, deadline, interval) do
    if condition_fn.() do
      :ok
    else
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(interval)
        do_assert_eventually(condition_fn, deadline, interval)
      else
        ExUnit.Assertions.flunk("Condition not met within timeout")
      end
    end
  end

  @doc """
  Waits for a mount to appear in the MountStore after a database change.

  This is useful for testing NOTIFY/LISTEN integration without manual reloads.

  ## Examples

      {:ok, path} = Paths.create_path(%{path: "api", user_id: user.id})
      {:ok, _mount} = Paths.update_path(path, %{mount_point: true})

      # Wait for NOTIFY to propagate
      wait_for_mount("/api")

      # Now can test routing
      conn = get(conn, "/proxies/api/test")
      assert json_response(conn, 200)
  """
  def wait_for_mount(full_path, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 2000)

    assert_eventually(
      fn ->
        case Plugboard.MountStore.match(full_path) do
          {:ok, _} -> true
          {:error, :not_found} -> false
        end
      end,
      timeout: timeout
    )
  end

  @doc """
  Waits for a mount to be removed from the MountStore.

  ## Examples

      {:ok, _} = Paths.delete_path(path)
      wait_for_mount_removal("/api")
  """
  def wait_for_mount_removal(full_path, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 2000)

    assert_eventually(
      fn ->
        case Plugboard.MountStore.match(full_path) do
          {:ok, _} -> false
          {:error, :not_found} -> true
        end
      end,
      timeout: timeout
    )
  end

  @doc """
  Waits for the ETS table to reach a specific size.

  Useful for testing that mounts are loaded at startup or during reconciliation.

  ## Examples

      # Wait for at least 5 mounts to be loaded
      wait_for_mount_count(5, :at_least)

      # Wait for exactly 3 mounts
      wait_for_mount_count(3, :exactly)
  """
  def wait_for_mount_count(expected_count, comparison \\ :at_least, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 2000)

    assert_eventually(
      fn ->
        actual_count = :ets.info(:plugboard_mounts, :size)

        case comparison do
          :at_least -> actual_count >= expected_count
          :exactly -> actual_count == expected_count
          :at_most -> actual_count <= expected_count
        end
      end,
      timeout: timeout
    )
  end

  @doc """
  Spawns a mock telephone process that registers itself with Horde.

  This is necessary because Horde.Registry.register() can only register
  the calling process (self()), not arbitrary PIDs. The spawned process
  will register itself and then wait indefinitely.

  ## Parameters
    - path_id: The path ID to register for

  ## Returns
    - pid: The PID of the spawned telephone process

  ## Examples

      path_id = Ecto.UUID.generate()
      telephone_pid = spawn_mock_telephone(path_id)

      # Verify it's registered
      assert {:ok, ^telephone_pid} = TelephoneRegistry.get_telephone(path_id)

      # Cleanup
      Process.exit(telephone_pid, :kill)
  """
  def spawn_mock_telephone(path_id) do
    parent = self()

    pid =
      spawn(fn ->
        # Register this process for the path
        :ok = Plugboard.TelephoneRegistry.register(path_id, self())

        # Signal parent that registration is complete
        send(parent, {:registered, self()})

        # Wait indefinitely
        Process.sleep(:infinity)
      end)

    # Wait for registration to complete
    receive do
      {:registered, ^pid} -> pid
    after
      5000 -> raise "Mock telephone failed to register within 5 seconds"
    end
  end

  @doc """
  Spawns multiple mock telephone processes for the same path.

  ## Examples

      path_id = Ecto.UUID.generate()
      [pid1, pid2, pid3] = spawn_mock_telephones(path_id, 3)

      # Verify all are registered
      assert TelephoneRegistry.count_telephones(path_id) == 3
  """
  def spawn_mock_telephones(path_id, count) when is_integer(count) and count > 0 do
    Enum.map(1..count, fn _ -> spawn_mock_telephone(path_id) end)
  end
end
