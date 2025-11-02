defmodule Plugboard.MountStoreTest do
  use Plugboard.DataCase, async: false

  import Plugboard.AccountsFixtures

  alias Plugboard.MountStore
  alias Plugboard.Paths

  setup do
    # Ensure MountStore is running and ETS table exists
    # The application supervisor should have started it, but we reload to ensure clean state
    MountStore.reload_all()
    :ok
  end

  describe "match/1" do
    test "matches exact mount point path" do
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "xyz",
          user_id: user.id
        })

      {:ok, _path} = Paths.update_path(path, %{mount_point: true})

      # Reload to ensure ETS is updated (tests don't wait for NOTIFY)
      MountStore.reload_all()

      assert {:ok, {"/xyz", "/", _mount_id}} = MountStore.match("/xyz")
    end

    test "matches mount point with additional path segments" do
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "xyz",
          user_id: user.id
        })

      {:ok, _path} = Paths.update_path(path, %{mount_point: true})

      # Reload to ensure ETS is updated (tests don't wait for NOTIFY)
      MountStore.reload_all()

      assert {:ok, {"/xyz", "/todo/items", _mount_id}} = MountStore.match("/xyz/todo/items")
    end

    test "matches nested mount point" do
      user = user_fixture()

      {:ok, parent} =
        Paths.create_path(%{
          path: "abc",
          user_id: user.id
        })

      {:ok, child} =
        Paths.create_path(%{
          path: "todo",
          parent_id: parent.id,
          user_id: user.id
        })

      {:ok, _child} = Paths.update_path(child, %{mount_point: true})

      # Reload to ensure ETS is updated (tests don't wait for NOTIFY)
      MountStore.reload_all()

      assert {:ok, {"/abc/todo", "/list", _mount_id}} = MountStore.match("/abc/todo/list")
    end

    test "matches the most specific mount point" do
      user = user_fixture()

      # Create two separate mount hierarchies to test specificity
      # /services mount
      {:ok, services_path} =
        Paths.create_path(%{
          path: "services",
          user_id: user.id
        })

      {:ok, _services_path} = Paths.update_path(services_path, %{mount_point: true})

      # /services-v2 mount (more specific in terms of path length)
      {:ok, services_v2_path} =
        Paths.create_path(%{
          path: "services-v2",
          user_id: user.id
        })

      {:ok, _services_v2_path} = Paths.update_path(services_v2_path, %{mount_point: true})

      # Reload to ensure ETS is updated (tests don't wait for NOTIFY)
      MountStore.reload_all()

      # Should match /services-v2 for longer path
      assert {:ok, {"/services-v2", "/users", _mount_id}} =
               MountStore.match("/services-v2/users")

      # Should match /services for shorter path
      assert {:ok, {"/services", "/users", _mount_id}} = MountStore.match("/services/users")
    end

    test "returns error when no mount point matches" do
      assert {:error, :not_found} = MountStore.match("/nonexistent")
      assert {:error, :not_found} = MountStore.match("/some/random/path")
    end

    test "normalizes request path by adding leading slash" do
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "test",
          user_id: user.id
        })

      {:ok, _path} = Paths.update_path(path, %{mount_point: true})

      # Reload to ensure ETS is updated (tests don't wait for NOTIFY)
      MountStore.reload_all()

      # Should work even without leading slash
      assert {:ok, {"/test", "/path", _mount_id}} = MountStore.match("test/path")
    end

    test "normalizes request path by removing trailing slash" do
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "test",
          user_id: user.id
        })

      {:ok, _path} = Paths.update_path(path, %{mount_point: true})

      # Reload to ensure ETS is updated (tests don't wait for NOTIFY)
      MountStore.reload_all()

      # Should work with trailing slash
      assert {:ok, {"/test", "/", _mount_id}} = MountStore.match("/test/")
    end

    test "handles root path correctly" do
      # Root path alone should not match anything
      assert {:error, :not_found} = MountStore.match("/")
    end

    test "computes correct forwarded path for exact match" do
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "service",
          user_id: user.id
        })

      {:ok, _path} = Paths.update_path(path, %{mount_point: true})

      # Reload to ensure ETS is updated (tests don't wait for NOTIFY)
      MountStore.reload_all()

      # Exact match should forward "/"
      assert {:ok, {"/service", "/", _mount_id}} = MountStore.match("/service")
    end

    test "computes correct forwarded path with nested segments" do
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "api",
          user_id: user.id
        })

      {:ok, _path} = Paths.update_path(path, %{mount_point: true})

      # Reload to ensure ETS is updated (tests don't wait for NOTIFY)
      MountStore.reload_all()

      assert {:ok, {"/api", "/v1/users/123/profile", _mount_id}} =
               MountStore.match("/api/v1/users/123/profile")
    end
  end

  describe "refresh_mount/1" do
    test "adds a new mount to ETS" do
      user = user_fixture()

      # Create path but don't mark as mount initially
      {:ok, path} =
        Paths.create_path(%{
          path: "newmount",
          user_id: user.id
        })

      # Should not match yet
      assert {:error, :not_found} = MountStore.match("/newmount")

      # Mark as mount
      {:ok, updated} = Paths.update_path(path, %{mount_point: true})

      # Wait a bit for NOTIFY to propagate, then verify with reload
      :timer.sleep(50)
      MountStore.reload_all()

      # Should now match
      assert {:ok, {"/newmount", "/", _mount_id}} = MountStore.match("/newmount")
      assert updated.id == elem(elem(MountStore.match("/newmount"), 1), 2)
    end

    test "removes a mount from ETS when unmarked" do
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "tempmount",
          user_id: user.id
        })

      {:ok, mounted_path} = Paths.update_path(path, %{mount_point: true})

      # Reload to ensure ETS is updated (tests don't wait for NOTIFY)
      MountStore.reload_all()

      # Should match
      assert {:ok, {"/tempmount", "/", _mount_id}} = MountStore.match("/tempmount")

      # Unmark as mount (use the mounted_path, not the original path)
      {:ok, _unmounted_path} = Paths.update_path(mounted_path, %{mount_point: false})

      # Reload to ensure ETS is updated
      MountStore.reload_all()

      # Should no longer match
      assert {:error, :not_found} = MountStore.match("/tempmount")
    end
  end

  describe "remove_mount/1" do
    test "removes deleted mount from ETS" do
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "deleteme",
          user_id: user.id
        })

      {:ok, _path} = Paths.update_path(path, %{mount_point: true})

      # Reload to ensure ETS is updated (tests don't wait for NOTIFY)
      MountStore.reload_all()

      # Should match
      assert {:ok, {"/deleteme", "/", _mount_id}} = MountStore.match("/deleteme")

      # Delete the path
      {:ok, _path} = Paths.delete_path(path)

      # Reload to ensure ETS is updated
      MountStore.reload_all()

      # Should no longer match
      assert {:error, :not_found} = MountStore.match("/deleteme")
    end
  end

  describe "reload_all/1" do
    test "reloads all mounts from database" do
      user = user_fixture()

      # Create multiple mounts
      {:ok, path1} =
        Paths.create_path(%{
          path: "mount1",
          user_id: user.id
        })

      {:ok, _path1} = Paths.update_path(path1, %{mount_point: true})

      {:ok, path2} =
        Paths.create_path(%{
          path: "mount2",
          user_id: user.id
        })

      {:ok, _path2} = Paths.update_path(path2, %{mount_point: true})

      # Force reload
      {:ok, count} = MountStore.reload_all()

      # Should have at least our 2 mounts (may have more from other tests)
      assert count >= 2

      # Both should match
      assert {:ok, {"/mount1", "/", _}} = MountStore.match("/mount1")
      assert {:ok, {"/mount2", "/", _}} = MountStore.match("/mount2")
    end
  end

  describe "list_mounts/0" do
    test "returns all mounts in ETS" do
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "listtest",
          user_id: user.id
        })

      {:ok, _path} = Paths.update_path(path, %{mount_point: true})

      # Reload to ensure ETS is updated (tests don't wait for NOTIFY)
      MountStore.reload_all()

      mounts = MountStore.list_mounts()

      # Should include our mount
      assert Enum.any?(mounts, fn {full_path, _} -> full_path == "/listtest" end)
    end
  end
end
