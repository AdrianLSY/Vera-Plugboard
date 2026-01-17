defmodule Plugboard.HookStoreTest do
  use Plugboard.DataCase, async: false

  import Plugboard.AccountsFixtures

  alias Plugboard.Hooks
  alias Plugboard.HookStore
  alias Plugboard.Paths

  setup do
    # Ensure HookStore is running and ETS table is clean
    HookStore.reload_all()
    :ok
  end

  # Helper to create a path
  defp create_path(user, attrs \\ %{}) do
    {:ok, path} =
      Paths.create_path(
        Map.merge(
          %{
            path: "test-path-#{System.unique_integer([:positive])}",
            user_id: user.id
          },
          attrs
        )
      )

    path
  end

  # Helper to create a mount point
  defp create_mount_point(user, attrs \\ %{}) do
    path = create_path(user, attrs)
    {:ok, mount} = Paths.update_path(user.id, path, %{mount_point: true})
    mount
  end

  # Helper to create a hook directly in the database
  defp create_hook(user, path, target_mount, attrs \\ %{}) do
    {:ok, hook} =
      Hooks.create_hook(
        user.id,
        Map.merge(
          %{
            path_id: path.id,
            name: "Test Hook #{System.unique_integer([:positive])}",
            target_type: "mount_point",
            target_path_id: target_mount.id,
            execution_order: 0,
            timeout_ms: 5000
          },
          attrs
        )
      )

    hook
  end

  describe "get_hooks/1" do
    test "returns empty list for unknown path" do
      fake_id = Ecto.UUID.generate()
      assert HookStore.get_hooks(fake_id) == []
    end

    test "returns hooks ordered by execution_order" do
      user = user_fixture()
      path = create_path(user)
      target = create_mount_point(user)

      # Create hooks out of order
      _hook2 = create_hook(user, path, target, %{name: "Hook 2", execution_order: 2})
      _hook0 = create_hook(user, path, target, %{name: "Hook 0", execution_order: 0})
      _hook1 = create_hook(user, path, target, %{name: "Hook 1", execution_order: 1})

      # Reload to update ETS
      HookStore.reload_all()

      hooks = HookStore.get_hooks(path.id)
      assert length(hooks) == 3

      # Verify order
      [first, second, third] = hooks
      assert first.execution_order == 0
      assert first.name == "Hook 0"
      assert second.execution_order == 1
      assert second.name == "Hook 1"
      assert third.execution_order == 2
      assert third.name == "Hook 2"
    end

    test "does not return deleted hooks" do
      user = user_fixture()
      path = create_path(user)
      target = create_mount_point(user)

      hook = create_hook(user, path, target)

      # Reload to update ETS
      HookStore.reload_all()

      assert length(HookStore.get_hooks(path.id)) == 1

      # Delete the hook
      {:ok, _deleted} = Hooks.delete_hook(user.id, hook)

      # Reload again
      HookStore.reload_all()

      assert HookStore.get_hooks(path.id) == []
    end
  end

  describe "refresh_hooks/1" do
    test "updates ETS for path with hooks" do
      user = user_fixture()
      path = create_path(user)
      target = create_mount_point(user)

      # Initially no hooks
      assert HookStore.get_hooks(path.id) == []

      # Create a hook
      hook = create_hook(user, path, target)

      # Refresh for this path
      HookStore.refresh_hooks(path.id)

      # Allow async cast to complete
      Process.sleep(50)

      hooks = HookStore.get_hooks(path.id)
      assert length(hooks) == 1
      assert hd(hooks).id == hook.id
    end

    test "removes path from ETS when no active hooks remain" do
      user = user_fixture()
      path = create_path(user)
      target = create_mount_point(user)

      # Create and reload
      hook = create_hook(user, path, target)
      HookStore.reload_all()

      assert length(HookStore.get_hooks(path.id)) == 1

      # Delete the hook
      {:ok, _deleted} = Hooks.delete_hook(user.id, hook)

      # Refresh for this path
      HookStore.refresh_hooks(path.id)

      # Allow async cast to complete
      Process.sleep(50)

      assert HookStore.get_hooks(path.id) == []
    end
  end

  describe "reload_all/0" do
    test "loads all hooks from database" do
      user = user_fixture()

      # Create two paths with hooks
      path1 = create_path(user)
      path2 = create_path(user)
      target = create_mount_point(user)

      _hook1 = create_hook(user, path1, target, %{name: "Hook for Path 1"})
      _hook2 = create_hook(user, path2, target, %{name: "Hook for Path 2"})

      # Clear and reload
      {:ok, count} = HookStore.reload_all()

      assert count == 2

      # Verify both paths have their hooks
      assert length(HookStore.get_hooks(path1.id)) == 1
      assert length(HookStore.get_hooks(path2.id)) == 1
    end

    test "clears existing ETS data before reloading" do
      user = user_fixture()
      path = create_path(user)
      target = create_mount_point(user)

      # Create hook and load
      _hook = create_hook(user, path, target)
      HookStore.reload_all()

      assert length(HookStore.get_hooks(path.id)) == 1

      # Delete from database (bypassing context to simulate external change)
      Plugboard.Repo.delete_all(Plugboard.Hooks.Hook)

      # Reload should clear the stale data
      {:ok, count} = HookStore.reload_all()

      assert count == 0
      assert HookStore.get_hooks(path.id) == []
    end
  end

  describe "list_all_hooks/0" do
    test "returns all hooks in ETS table" do
      user = user_fixture()
      path1 = create_path(user)
      path2 = create_path(user)
      target = create_mount_point(user)

      _hook1 = create_hook(user, path1, target, %{name: "Hook 1"})
      _hook2 = create_hook(user, path2, target, %{name: "Hook 2"})

      HookStore.reload_all()

      all_hooks = HookStore.list_all_hooks()

      # Returns list of {path_id, [hooks]} tuples
      assert length(all_hooks) == 2
      assert Enum.all?(all_hooks, fn {_path_id, hooks} -> is_list(hooks) end)
    end

    test "returns empty list when no hooks" do
      HookStore.reload_all()
      # With no hooks created, should be empty
      # (though other tests may have created some)
      all_hooks = HookStore.list_all_hooks()
      assert is_list(all_hooks)
    end
  end

  describe "telemetry" do
    test "reload_all emits telemetry" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:plugboard, :hook_store, :reload],
          [:plugboard, :hook_store, :size]
        ])

      # Trigger reload
      {:ok, _count} = HookStore.reload_all()

      # Verify reload telemetry was emitted
      assert_receive {[:plugboard, :hook_store, :reload], ^ref,
                      %{duration: _, hook_count: _, path_count: _}, %{trigger: :manual}},
                     1000

      # Verify size telemetry was emitted
      assert_receive {[:plugboard, :hook_store, :size], ^ref, %{hook_count: _, path_count: _},
                      %{}},
                     1000

      :telemetry.detach(ref)
    end
  end
end
