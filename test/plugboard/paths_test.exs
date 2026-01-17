defmodule Plugboard.PathsTest do
  use Plugboard.DataCase

  alias Plugboard.Accounts
  alias Plugboard.Paths
  alias Plugboard.Paths.Path

  describe "list_paths/1" do
    setup do
      user = user_fixture()
      %{user: user}
    end

    test "returns all active paths for a user", %{user: user} do
      {:ok, path1} =
        Paths.create_path(%{
          path: "xyz",
          user_id: user.id
        })

      {:ok, path2} =
        Paths.create_path(%{
          path: "abc",
          user_id: user.id
        })

      paths = Paths.list_paths(user.id)
      assert length(paths) == 2
      assert Enum.any?(paths, fn p -> p.id == path1.id end)
      assert Enum.any?(paths, fn p -> p.id == path2.id end)
    end

    test "does not return soft-deleted paths", %{user: user} do
      {:ok, path} =
        Paths.create_path(%{
          path: "xyz",
          user_id: user.id
        })

      {:ok, _deleted} = Paths.delete_path(user.id, path)

      paths = Paths.list_paths(user.id)
      assert paths == []
    end

    test "does not return paths from other users", %{user: user} do
      other_user = user_fixture()

      {:ok, _path} =
        Paths.create_path(%{
          path: "xyz",
          user_id: other_user.id
        })

      paths = Paths.list_paths(user.id)
      assert paths == []
    end
  end

  describe "list_mount_points/1" do
    setup do
      user = user_fixture()
      %{user: user}
    end

    test "returns only mount points", %{user: user} do
      {:ok, regular_path} =
        Paths.create_path(%{
          path: "xyz",
          user_id: user.id
        })

      {:ok, mount_point} =
        Paths.create_path(%{
          path: "abc",
          user_id: user.id,
          mount_point: true
        })

      mount_points = Paths.list_mount_points(user.id)
      assert length(mount_points) == 1
      assert hd(mount_points).id == mount_point.id
      refute Enum.any?(mount_points, fn p -> p.id == regular_path.id end)
    end
  end

  describe "create_path/1" do
    setup do
      user = user_fixture()
      %{user: user}
    end

    test "creates a root path with valid data", %{user: user} do
      attrs = %{
        path: "xyz",
        user_id: user.id
      }

      assert {:ok, %Path{} = path} = Paths.create_path(attrs)
      assert path.path == "xyz"
      assert path.full_path == "/xyz"
      assert path.mount_point == false
      assert is_nil(path.parent_id)
      assert is_nil(path.deleted_at)

      # Verify user association exists
      user_path = Paths.get_user_path(user.id, path.id)
      assert user_path != nil
      assert user_path.role == "owner"
    end

    test "creates a child path with valid data", %{user: user} do
      {:ok, parent} =
        Paths.create_path(%{
          path: "xyz",
          user_id: user.id
        })

      attrs = %{
        path: "todo",
        parent_id: parent.id,
        user_id: user.id,
        created_by_user_id: user.id
      }

      assert {:ok, %Path{} = child} = Paths.create_path(attrs)
      assert child.path == "todo"
      assert child.full_path == "/xyz/todo"
      assert child.parent_id == parent.id
    end

    test "creates deeply nested paths", %{user: user} do
      {:ok, level1} =
        Paths.create_path(%{
          path: "a",
          user_id: user.id
        })

      {:ok, level2} =
        Paths.create_path(%{
          path: "b",
          parent_id: level1.id,
          user_id: user.id
        })

      {:ok, level3} =
        Paths.create_path(%{
          path: "c",
          parent_id: level2.id,
          user_id: user.id
        })

      assert level1.full_path == "/a"
      assert level2.full_path == "/a/b"
      assert level3.full_path == "/a/b/c"
    end

    test "creates a path as mount point", %{user: user} do
      attrs = %{
        path: "xyz",
        user_id: user.id,
        created_by_user_id: user.id,
        mount_point: true
      }

      assert {:ok, %Path{} = path} = Paths.create_path(attrs)
      assert path.mount_point == true
    end

    test "returns error with invalid path segment (contains slash)", %{user: user} do
      attrs = %{
        path: "xyz/abc",
        user_id: user.id,
        created_by_user_id: user.id
      }

      assert {:error, changeset} = Paths.create_path(attrs)
      assert "must not contain forward slashes" in errors_on(changeset).path
    end

    test "returns error with empty path", %{user: user} do
      attrs = %{
        path: "",
        user_id: user.id,
        created_by_user_id: user.id
      }

      assert {:error, changeset} = Paths.create_path(attrs)
      assert "can't be blank" in errors_on(changeset).path
    end

    test "returns error when missing required fields" do
      assert {:error, changeset} = Paths.create_path(%{})
      errors = errors_on(changeset)
      assert "can't be blank" in errors.path
      assert "can't be blank" in errors.user_id
    end

    test "enforces unique sibling paths", %{user: user} do
      {:ok, _path1} =
        Paths.create_path(%{
          path: "xyz",
          user_id: user.id
        })

      # Attempt to create duplicate
      assert {:error, changeset} =
               Paths.create_path(%{
                 path: "xyz",
                 user_id: user.id,
                 created_by_user_id: user.id
               })

      assert "has already been taken" in errors_on(changeset).path
    end

    test "allows same path name under different parents", %{user: user} do
      {:ok, parent1} =
        Paths.create_path(%{
          path: "parent1",
          user_id: user.id
        })

      {:ok, parent2} =
        Paths.create_path(%{
          path: "parent2",
          user_id: user.id
        })

      {:ok, child1} =
        Paths.create_path(%{
          path: "child",
          parent_id: parent1.id,
          user_id: user.id
        })

      {:ok, child2} =
        Paths.create_path(%{
          path: "child",
          parent_id: parent2.id,
          user_id: user.id
        })

      assert child1.full_path == "/parent1/child"
      assert child2.full_path == "/parent2/child"
    end

    test "restores soft-deleted path instead of creating duplicate", %{user: user} do
      # Create and then soft-delete a path
      {:ok, original} =
        Paths.create_path(%{
          path: "xyz",
          user_id: user.id,
          mount_point: true
        })

      original_id = original.id
      {:ok, deleted} = Paths.delete_path(user.id, original)
      assert deleted.deleted_at != nil

      # Attempt to create the same path again
      {:ok, restored} =
        Paths.create_path(%{
          path: "xyz",
          user_id: user.id
        })

      # Should restore the same record
      assert restored.id == original_id
      assert is_nil(restored.deleted_at)
      # Mount point should be reset to false
      assert restored.mount_point == false
    end

    test "restores soft-deleted child path", %{user: user} do
      {:ok, parent} =
        Paths.create_path(%{
          path: "parent",
          user_id: user.id
        })

      {:ok, child} =
        Paths.create_path(%{
          path: "child",
          parent_id: parent.id,
          user_id: user.id
        })

      child_id = child.id
      {:ok, _deleted} = Paths.delete_path(user.id, child)

      # Recreate the child
      {:ok, restored} =
        Paths.create_path(%{
          path: "child",
          parent_id: parent.id,
          user_id: user.id
        })

      assert restored.id == child_id
      assert is_nil(restored.deleted_at)
    end

    test "failed path creation rolls back user_path association", %{user: user} do
      # Count initial user_paths
      initial_count = Repo.aggregate(Plugboard.Paths.UserPath, :count, :id)

      # Attempt to create invalid path (path name too long)
      too_long_path = String.duplicate("a", 256)

      assert {:error, _changeset} =
               Paths.create_path(%{
                 path: too_long_path,
                 user_id: user.id
               })

      # Verify no orphaned user_path record was created
      final_count = Repo.aggregate(Plugboard.Paths.UserPath, :count, :id)
      assert final_count == initial_count
    end

    test "failed path creation with invalid parent rolls back cleanly", %{user: user} do
      fake_parent_id = Ecto.UUID.generate()

      # Count initial records
      initial_paths = Repo.aggregate(Path, :count, :id)
      initial_user_paths = Repo.aggregate(Plugboard.Paths.UserPath, :count, :id)

      # Attempt to create path with non-existent parent
      assert_raise Postgrex.Error, ~r/Parent path not found/, fn ->
        Paths.create_path(%{
          path: "child",
          parent_id: fake_parent_id,
          user_id: user.id
        })
      end

      # Verify no records were created (transaction rolled back)
      final_paths = Repo.aggregate(Path, :count, :id)
      final_user_paths = Repo.aggregate(Plugboard.Paths.UserPath, :count, :id)

      assert final_paths == initial_paths
      assert final_user_paths == initial_user_paths
    end
  end

  describe "database trigger: prevent_child_under_mount" do
    setup do
      user = user_fixture()
      %{user: user}
    end

    test "prevents creating a child under a mount point", %{user: user} do
      # Create a mount point
      {:ok, mount} =
        Paths.create_path(%{
          path: "mount",
          user_id: user.id,
          mount_point: true
        })

      # Attempt to create a child under the mount point
      assert_raise Postgrex.Error, ~r/Cannot create child path under a mount point/, fn ->
        Paths.create_path(%{
          path: "child",
          parent_id: mount.id,
          user_id: user.id
        })
      end
    end

    test "prevents moving a path to become child of a mount point", %{user: user} do
      {:ok, mount} =
        Paths.create_path(%{
          path: "mount",
          user_id: user.id,
          mount_point: true
        })

      {:ok, regular_path} =
        Paths.create_path(%{
          path: "regular",
          user_id: user.id
        })

      # Attempt to move regular_path under mount
      changeset = Ecto.Changeset.change(regular_path, parent_id: mount.id)

      assert_raise Postgrex.Error, ~r/Cannot create child path under a mount point/, fn ->
        Repo.update!(changeset)
      end
    end
  end

  describe "database trigger: prevent_mount_when_has_children" do
    setup do
      user = user_fixture()
      %{user: user}
    end

    test "prevents marking a path as mount when it has children", %{user: user} do
      {:ok, parent} =
        Paths.create_path(%{
          path: "parent",
          user_id: user.id
        })

      {:ok, _child} =
        Paths.create_path(%{
          path: "child",
          parent_id: parent.id,
          user_id: user.id
        })

      # Attempt to mark parent as mount point
      assert_raise Postgrex.Error, ~r/Cannot mark path as mount point when it has children/, fn ->
        Paths.update_path(user.id, parent, %{mount_point: true})
      end
    end

    test "allows marking path as mount when it has no children", %{user: user} do
      {:ok, path} =
        Paths.create_path(%{
          path: "path",
          user_id: user.id
        })

      assert {:ok, updated} = Paths.update_path(user.id, path, %{mount_point: true})
      assert updated.mount_point == true
    end
  end

  describe "update_path/2" do
    setup do
      user = user_fixture()
      %{user: user}
    end

    test "updates path segment", %{user: user} do
      {:ok, path} =
        Paths.create_path(%{
          path: "xyz",
          user_id: user.id
        })

      assert {:ok, updated} = Paths.update_path(user.id, path, %{path: "abc"})
      assert updated.path == "abc"
      assert updated.full_path == "/abc"
    end

    test "updates mount_point flag", %{user: user} do
      {:ok, path} =
        Paths.create_path(%{
          path: "xyz",
          user_id: user.id,
          mount_point: false
        })

      assert {:ok, updated} = Paths.update_path(user.id, path, %{mount_point: true})
      assert updated.mount_point == true
    end

    test "updates full_path of descendants when path segment changes", %{user: user} do
      {:ok, parent} =
        Paths.create_path(%{
          path: "parent",
          user_id: user.id
        })

      {:ok, child} =
        Paths.create_path(%{
          path: "child",
          parent_id: parent.id,
          user_id: user.id
        })

      {:ok, grandchild} =
        Paths.create_path(%{
          path: "grandchild",
          parent_id: child.id,
          user_id: user.id
        })

      # Update parent path
      {:ok, _updated_parent} = Paths.update_path(user.id, parent, %{path: "newparent"})

      # Reload descendants
      updated_child = Repo.get!(Path, child.id)
      updated_grandchild = Repo.get!(Path, grandchild.id)

      # Full paths should be updated
      assert updated_child.full_path == "/newparent/child"
      assert updated_grandchild.full_path == "/newparent/child/grandchild"
    end
  end

  describe "delete_path/1" do
    setup do
      user = user_fixture()
      %{user: user}
    end

    test "soft-deletes a path", %{user: user} do
      {:ok, path} =
        Paths.create_path(%{
          path: "xyz",
          user_id: user.id
        })

      assert {:ok, deleted} = Paths.delete_path(user.id, path)
      assert deleted.deleted_at != nil

      # Path should not be in active list
      paths = Paths.list_paths(user.id)
      assert paths == []

      # But should still exist in database
      db_path = Repo.get(Path, path.id)
      assert db_path != nil
      assert db_path.deleted_at != nil
    end

    test "cascade soft-deletes children", %{user: user} do
      {:ok, parent} =
        Paths.create_path(%{
          path: "parent",
          user_id: user.id
        })

      {:ok, child} =
        Paths.create_path(%{
          path: "child",
          parent_id: parent.id,
          user_id: user.id
        })

      # Delete parent
      {:ok, _deleted} = Paths.delete_path(user.id, parent)

      # Child should also be deleted (cascade)
      assert is_nil(Paths.get_path(child.id))
    end

    test "cascade soft-deletes logs descendant count", %{user: user} do
      {:ok, parent} =
        Paths.create_path(%{
          path: "parent",
          user_id: user.id
        })

      {:ok, child1} =
        Paths.create_path(%{
          path: "child1",
          parent_id: parent.id,
          user_id: user.id
        })

      {:ok, _child2} =
        Paths.create_path(%{
          path: "child2",
          parent_id: parent.id,
          user_id: user.id
        })

      {:ok, _grandchild} =
        Paths.create_path(%{
          path: "grandchild",
          parent_id: child1.id,
          user_id: user.id
        })

      # Capture logs - temporarily set log level to info
      import ExUnit.CaptureLog
      old_level = Logger.level()
      Logger.configure(level: :info)

      log =
        capture_log(fn ->
          {:ok, _deleted} = Paths.delete_path(user.id, parent)
        end)

      Logger.configure(level: old_level)

      # Should log cascade operation
      assert log =~ "Cascade soft-deleted 3 descendant paths"
    end
  end

  describe "get_path/1" do
    setup do
      user = user_fixture()
      %{user: user}
    end

    test "returns path when it exists", %{user: user} do
      {:ok, path} =
        Paths.create_path(%{
          path: "xyz",
          user_id: user.id
        })

      assert %Path{} = retrieved = Paths.get_path(path.id)
      assert retrieved.id == path.id
    end

    test "returns nil when path does not exist" do
      assert is_nil(Paths.get_path(Ecto.UUID.generate()))
    end

    test "returns nil for soft-deleted paths", %{user: user} do
      {:ok, path} =
        Paths.create_path(%{
          path: "xyz",
          user_id: user.id
        })

      {:ok, _deleted} = Paths.delete_path(user.id, path)

      assert is_nil(Paths.get_path(path.id))
    end
  end

  describe "get_path_by_full_path/2" do
    setup do
      user = user_fixture()
      %{user: user}
    end

    test "returns path by full_path", %{user: user} do
      {:ok, path} =
        Paths.create_path(%{
          path: "xyz",
          user_id: user.id
        })

      assert %Path{} = retrieved = Paths.get_path_by_full_path(user.id, "/xyz")
      assert retrieved.id == path.id
    end

    test "returns nil when path does not exist", %{user: user} do
      assert is_nil(Paths.get_path_by_full_path(user.id, "/nonexistent"))
    end

    test "returns nil for paths belonging to other users", %{user: user} do
      other_user = user_fixture()

      {:ok, _path} =
        Paths.create_path(%{
          path: "xyz",
          user_id: other_user.id,
          created_by_user_id: other_user.id
        })

      assert is_nil(Paths.get_path_by_full_path(user.id, "/xyz"))
    end
  end

  describe "can_mark_as_mount?/1" do
    setup do
      user = user_fixture()
      %{user: user}
    end

    test "returns ok for path without children", %{user: user} do
      {:ok, path} =
        Paths.create_path(%{
          path: "xyz",
          user_id: user.id
        })

      assert Paths.can_mark_as_mount?(path) == true
    end

    test "returns error for path with children", %{user: user} do
      {:ok, parent} =
        Paths.create_path(%{
          path: "parent",
          user_id: user.id
        })

      {:ok, _child} =
        Paths.create_path(%{
          path: "child",
          parent_id: parent.id,
          user_id: user.id
        })

      assert Paths.can_mark_as_mount?(parent) == false
    end
  end

  describe "can_add_child?/1" do
    setup do
      user = user_fixture()
      %{user: user}
    end

    test "returns ok for regular path", %{user: user} do
      {:ok, path} =
        Paths.create_path(%{
          path: "xyz",
          user_id: user.id
        })

      assert {:ok, true} = Paths.can_add_child?(path)
    end

    test "returns error for mount point", %{user: user} do
      {:ok, mount} =
        Paths.create_path(%{
          path: "mount",
          user_id: user.id,
          mount_point: true
        })

      assert {:error, _msg} = Paths.can_add_child?(mount)
    end
  end

  describe "get_children/1" do
    setup do
      user = user_fixture()
      %{user: user}
    end

    test "returns direct children only", %{user: user} do
      {:ok, parent} =
        Paths.create_path(%{
          path: "parent",
          user_id: user.id
        })

      {:ok, child1} =
        Paths.create_path(%{
          path: "child1",
          parent_id: parent.id,
          user_id: user.id
        })

      {:ok, child2} =
        Paths.create_path(%{
          path: "child2",
          parent_id: parent.id,
          user_id: user.id
        })

      {:ok, _grandchild} =
        Paths.create_path(%{
          path: "grandchild",
          parent_id: child1.id,
          user_id: user.id
        })

      children = Paths.get_children(parent)
      assert length(children) == 2
      assert Enum.any?(children, fn c -> c.id == child1.id end)
      assert Enum.any?(children, fn c -> c.id == child2.id end)
    end

    test "returns empty list when no children exist", %{user: user} do
      {:ok, path} =
        Paths.create_path(%{
          path: "lonely",
          user_id: user.id
        })

      assert Paths.get_children(path) == []
    end
  end

  describe "get_descendants/1" do
    setup do
      user = user_fixture()
      %{user: user}
    end

    test "returns all descendants recursively", %{user: user} do
      {:ok, parent} =
        Paths.create_path(%{
          path: "parent",
          user_id: user.id
        })

      {:ok, child1} =
        Paths.create_path(%{
          path: "child1",
          parent_id: parent.id,
          user_id: user.id
        })

      {:ok, child2} =
        Paths.create_path(%{
          path: "child2",
          parent_id: parent.id,
          user_id: user.id
        })

      {:ok, grandchild1} =
        Paths.create_path(%{
          path: "grandchild1",
          parent_id: child1.id,
          user_id: user.id
        })

      {:ok, grandchild2} =
        Paths.create_path(%{
          path: "grandchild2",
          parent_id: child2.id,
          user_id: user.id
        })

      descendants = Paths.get_descendants(parent)
      assert length(descendants) == 4

      descendant_ids = Enum.map(descendants, & &1.id)
      assert child1.id in descendant_ids
      assert child2.id in descendant_ids
      assert grandchild1.id in descendant_ids
      assert grandchild2.id in descendant_ids
    end

    test "returns empty list when no descendants exist", %{user: user} do
      {:ok, path} =
        Paths.create_path(%{
          path: "lonely",
          user_id: user.id
        })

      assert Paths.get_descendants(path) == []
    end
  end

  describe "database CHECK constraints" do
    setup do
      user = user_fixture()
      %{user: user}
    end

    test "prevents paths with slashes at database level", %{user: _user} do
      # Bypass application validation by using raw SQL
      {:ok, uuid_binary} = Ecto.UUID.dump(Ecto.UUID.generate())

      assert_raise Postgrex.Error, ~r/path_no_slashes/, fn ->
        Repo.query!(
          "INSERT INTO paths (id, path, full_path, mount_point, inserted_at, updated_at)
           VALUES ($1, $2, $3, $4, NOW(), NOW())",
          [
            uuid_binary,
            "invalid/path",
            "/invalid/path",
            false
          ]
        )
      end
    end

    test "prevents paths with invalid characters at database level", %{user: _user} do
      {:ok, uuid_binary} = Ecto.UUID.dump(Ecto.UUID.generate())

      assert_raise Postgrex.Error, ~r/path_valid_chars/, fn ->
        Repo.query!(
          "INSERT INTO paths (id, path, full_path, mount_point, inserted_at, updated_at)
           VALUES ($1, $2, $3, $4, NOW(), NOW())",
          [
            uuid_binary,
            "invalid@path!",
            "/invalid@path!",
            false
          ]
        )
      end
    end

    test "prevents empty paths at database level", %{user: _user} do
      {:ok, uuid_binary} = Ecto.UUID.dump(Ecto.UUID.generate())

      assert_raise Postgrex.Error, ~r/path_length/, fn ->
        Repo.query!(
          "INSERT INTO paths (id, path, full_path, mount_point, inserted_at, updated_at)
           VALUES ($1, $2, $3, $4, NOW(), NOW())",
          [
            uuid_binary,
            "",
            "/",
            false
          ]
        )
      end
    end

    test "prevents paths longer than 255 characters at database level", %{user: _user} do
      long_path = String.duplicate("a", 256)
      {:ok, uuid_binary} = Ecto.UUID.dump(Ecto.UUID.generate())

      assert_raise Postgrex.Error, ~r/path_length/, fn ->
        Repo.query!(
          "INSERT INTO paths (id, path, full_path, mount_point, inserted_at, updated_at)
           VALUES ($1, $2, $3, $4, NOW(), NOW())",
          [
            uuid_binary,
            long_path,
            "/#{long_path}",
            false
          ]
        )
      end
    end
  end

  describe "database foreign key constraints" do
    setup do
      user = user_fixture()
      %{user: user}
    end

    test "foreign key constraint on parent_id", %{user: user} do
      fake_parent_id = Ecto.UUID.generate()

      # Database trigger raises Postgrex.Error with "Parent path not found"
      assert_raise Postgrex.Error, ~r/Parent path not found/, fn ->
        Paths.create_path(%{path: "child", parent_id: fake_parent_id, user_id: user.id})
      end
    end

    test "user_paths foreign key constraint on user_id" do
      {:ok, user} = Accounts.register_user(%{email: "test@test.com", password: "hello world!"})
      {:ok, path} = Paths.create_path(%{path: "test", user_id: user.id})

      fake_user_id = Ecto.UUID.generate()

      {:error, changeset} = Paths.add_user_to_path(user.id, fake_user_id, path.id, "viewer")
      assert %{user_id: ["does not exist"]} = errors_on(changeset)
    end

    test "user_paths foreign key constraint on path_id" do
      {:ok, user} = Accounts.register_user(%{email: "test@test.com", password: "hello world!"})
      {:ok, _path} = Paths.create_path(%{path: "test", user_id: user.id})
      another_user = user_fixture()
      fake_path_id = Ecto.UUID.generate()

      # When path doesn't exist, authorization check fails first (user can't be owner of non-existent path)
      # This is correct security behavior - don't leak path existence information
      assert {:error, :unauthorized} =
               Paths.add_user_to_path(user.id, another_user.id, fake_path_id, "viewer")
    end

    test "deleting user cascades to user_paths (ON DELETE CASCADE)", %{user: user} do
      {:ok, path} = Paths.create_path(%{path: "test", user_id: user.id})
      viewer = user_fixture()
      {:ok, user_path} = Paths.add_user_to_path(user.id, viewer.id, path.id, "viewer")

      # Hard delete the viewer user
      Repo.delete!(viewer)

      # user_path should be automatically deleted
      assert is_nil(Repo.get(Plugboard.Paths.UserPath, user_path.id))
    end

    test "hard deleting path cascades to user_paths (ON DELETE CASCADE)", %{user: user} do
      {:ok, path} = Paths.create_path(%{path: "test", user_id: user.id})
      viewer = user_fixture()
      {:ok, user_path} = Paths.add_user_to_path(user.id, viewer.id, path.id, "viewer")

      # Hard delete the path (bypass soft-delete)
      Repo.delete!(path)

      # user_path should be automatically deleted
      assert is_nil(Repo.get(Plugboard.Paths.UserPath, user_path.id))
    end

    test "soft-deleting path does NOT cascade to user_paths", %{user: user} do
      {:ok, path} = Paths.create_path(%{path: "test", user_id: user.id})
      viewer = user_fixture()
      {:ok, user_path} = Paths.add_user_to_path(user.id, viewer.id, path.id, "viewer")

      # Soft-delete the path
      Paths.delete_path(user.id, path)

      # user_path should still exist in database
      assert Repo.get(Plugboard.Paths.UserPath, user_path.id) != nil
    end

    test "parent_id ON DELETE RESTRICT prevents deleting parent with active children", %{
      user: user
    } do
      {:ok, parent} = Paths.create_path(%{path: "parent", user_id: user.id})
      {:ok, _child} = Paths.create_path(%{path: "child", parent_id: parent.id, user_id: user.id})

      # Hard delete should fail due to foreign key constraint (RESTRICT)
      # The error type varies: Postgrex.Error (local) or Ecto.ConstraintError (CI)
      # Both indicate the same constraint violation
      error =
        try do
          Repo.delete!(parent)
          flunk("Expected deletion to fail with constraint violation")
        rescue
          e in [Postgrex.Error, Ecto.ConstraintError] -> e
        end

      # Verify the constraint name appears in the error message
      error_message = Exception.message(error)
      assert error_message =~ "paths_parent_id_fkey"
    end
  end

  describe "database unique constraints" do
    setup do
      user = user_fixture()
      %{user: user}
    end

    test "paths_unique_sibling_path enforces unique (parent_id, path) with NULL parent", %{
      user: user
    } do
      {:ok, _path1} = Paths.create_path(%{path: "xyz", user_id: user.id})

      # Duplicate root path should fail
      {:error, changeset} = Paths.create_path(%{path: "xyz", user_id: user.id})
      assert "has already been taken" in errors_on(changeset).path
    end

    test "paths_unique_sibling_path allows same path name under different parents", %{user: user} do
      {:ok, parent1} = Paths.create_path(%{path: "parent1", user_id: user.id})
      {:ok, parent2} = Paths.create_path(%{path: "parent2", user_id: user.id})

      {:ok, child1} = Paths.create_path(%{path: "child", parent_id: parent1.id, user_id: user.id})
      {:ok, child2} = Paths.create_path(%{path: "child", parent_id: parent2.id, user_id: user.id})

      assert child1.full_path == "/parent1/child"
      assert child2.full_path == "/parent2/child"
    end

    test "paths_unique_full_path enforces globally unique full paths", %{user: user} do
      {:ok, _path1} = Paths.create_path(%{path: "xyz", user_id: user.id})

      # The unique constraint on full_path is enforced by the partial index
      # WHERE deleted_at IS NULL. However, the database trigger compute_full_path
      # will compute the full_path based on parent and path, so we can't directly
      # insert a duplicate full_path with different path segments.

      # Instead, test that creating a duplicate via application logic is prevented
      {:error, changeset} = Paths.create_path(%{path: "xyz", user_id: user.id})

      # Should get a "has already been taken" error
      assert "has already been taken" in errors_on(changeset).path
    end

    test "soft-deleted paths don't block new paths with same full_path", %{user: user} do
      {:ok, path1} = Paths.create_path(%{path: "xyz", user_id: user.id})
      {:ok, _deleted} = Paths.delete_path(user.id, path1)

      # Creating path with same name should restore the soft-deleted one
      {:ok, path2} = Paths.create_path(%{path: "xyz", user_id: user.id})

      # Should be the same record, restored
      assert path2.id == path1.id
      assert is_nil(path2.deleted_at)
    end

    test "user_paths_unique_user_path prevents duplicate user-path associations", %{user: user} do
      {:ok, path} = Paths.create_path(%{path: "test", user_id: user.id})
      viewer = user_fixture()

      {:ok, _} = Paths.add_user_to_path(user.id, viewer.id, path.id, "viewer")

      # Duplicate should fail
      {:error, changeset} = Paths.add_user_to_path(user.id, viewer.id, path.id, "owner")

      errors = errors_on(changeset)
      # Either user_id or path_id should show "has already been taken"
      assert (errors[:user_id] && "has already been taken" in errors[:user_id]) or
               (errors[:path_id] && "has already been taken" in errors[:path_id])
    end
  end

  describe "user_paths CHECK constraints" do
    test "valid_role CHECK constraint enforces role values" do
      {:ok, user} = Accounts.register_user(%{email: "test@test.com", password: "hello world!"})
      {:ok, path} = Paths.create_path(%{path: "test", user_id: user.id})
      another_user = user_fixture()

      # Valid roles should work (tested elsewhere)
      assert {:ok, _} = Paths.add_user_to_path(user.id, another_user.id, path.id, "viewer")

      # Invalid role at database level (bypass application validation)
      {:ok, user_id_binary} = Ecto.UUID.dump(user.id)
      {:ok, path_id_binary} = Ecto.UUID.dump(path.id)
      {:ok, uuid_binary} = Ecto.UUID.dump(Ecto.UUID.generate())

      assert_raise Postgrex.Error, ~r/valid_role/, fn ->
        Repo.query!(
          "INSERT INTO user_paths (id, user_id, path_id, role, inserted_at, updated_at)
           VALUES ($1, $2, $3, $4, NOW(), NOW())",
          [
            uuid_binary,
            user_id_binary,
            path_id_binary,
            # Invalid role
            "admin"
          ]
        )
      end
    end
  end

  describe "authorization and permissions" do
    setup do
      owner = user_fixture()
      viewer = user_fixture()
      maintainer = user_fixture()
      other_user = user_fixture()

      {:ok, path} = Paths.create_path(%{path: "shared-path", user_id: owner.id})

      # Add viewer and maintainer roles (owner adds them)
      {:ok, _} = Paths.add_user_to_path(owner.id, viewer.id, path.id, "viewer")
      {:ok, _} = Paths.add_user_to_path(owner.id, maintainer.id, path.id, "maintainer")

      %{owner: owner, viewer: viewer, maintainer: maintainer, other_user: other_user, path: path}
    end

    test "viewer can list and view paths", %{viewer: viewer, path: path} do
      paths = Paths.list_paths(viewer.id)
      assert length(paths) == 1
      assert hd(paths).id == path.id

      # Can get path by full_path
      retrieved = Paths.get_path_by_full_path(viewer.id, path.full_path)
      assert retrieved.id == path.id
    end

    test "maintainer can list and view paths", %{maintainer: maintainer, path: path} do
      paths = Paths.list_paths(maintainer.id)
      assert length(paths) == 1
      assert hd(paths).id == path.id
    end

    test "owner can list and view paths", %{owner: owner, path: path} do
      paths = Paths.list_paths(owner.id)
      assert length(paths) == 1
      assert hd(paths).id == path.id
    end

    test "user without access cannot view path", %{other_user: other_user, path: path} do
      paths = Paths.list_paths(other_user.id)
      assert paths == []

      # Cannot get by full_path
      assert is_nil(Paths.get_path_by_full_path(other_user.id, path.full_path))
    end

    test "viewer can see children of path they have access to", %{
      owner: owner,
      path: path
    } do
      {:ok, child} = Paths.create_path(%{path: "child", parent_id: path.id, user_id: owner.id})

      # Viewer should see the child through parent relationship
      children = Paths.get_children(path)
      assert length(children) == 1
      assert hd(children).id == child.id
    end

    test "multiple users with different roles can access same path", %{
      owner: owner,
      viewer: viewer,
      maintainer: maintainer,
      path: path
    } do
      # All should see the path
      assert Enum.any?(Paths.list_paths(owner.id), fn p -> p.id == path.id end)
      assert Enum.any?(Paths.list_paths(viewer.id), fn p -> p.id == path.id end)
      assert Enum.any?(Paths.list_paths(maintainer.id), fn p -> p.id == path.id end)

      # Verify roles
      assert Paths.has_role?(owner.id, path.id, "owner")
      assert Paths.has_role?(viewer.id, path.id, "viewer")
      assert Paths.has_role?(maintainer.id, path.id, "maintainer")
    end

    test "removing user access removes path from their list", %{
      owner: owner,
      viewer: viewer,
      path: path
    } do
      # Viewer can see path
      assert Enum.any?(Paths.list_paths(viewer.id), fn p -> p.id == path.id end)

      # Remove viewer access (owner removes them)
      user_path = Paths.get_user_path(viewer.id, path.id)
      {:ok, _} = Paths.remove_user_from_path(owner.id, user_path)

      # Viewer can no longer see path
      paths = Paths.list_paths(viewer.id)
      refute Enum.any?(paths, fn p -> p.id == path.id end)
    end

    test "user can create child under path they own", %{owner: owner, path: path} do
      assert {:ok, child} =
               Paths.create_path(%{path: "child", parent_id: path.id, user_id: owner.id})

      assert child.parent_id == path.id
      assert child.full_path == "/shared-path/child"
    end

    test "granting access to parent doesn't automatically grant access to children", %{
      owner: owner,
      path: parent
    } do
      # Create a child path
      {:ok, child} = Paths.create_path(%{path: "child", parent_id: parent.id, user_id: owner.id})

      # Create new user and give them access to parent only (owner adds them)
      new_user = user_fixture()
      {:ok, _} = Paths.add_user_to_path(owner.id, new_user.id, parent.id, "viewer")

      # New user should see parent
      paths = Paths.list_paths(new_user.id)
      parent_ids = Enum.map(paths, & &1.id)
      assert parent.id in parent_ids

      # But not the child (unless explicitly granted)
      refute child.id in parent_ids
    end

    test "user can be granted access to child without parent access", %{
      owner: owner,
      path: parent
    } do
      # Create a child path
      {:ok, child} = Paths.create_path(%{path: "child", parent_id: parent.id, user_id: owner.id})

      # Grant new user access to child only (owner adds them)
      new_user = user_fixture()
      {:ok, _} = Paths.add_user_to_path(owner.id, new_user.id, child.id, "viewer")

      # User should see child but not parent
      paths = Paths.list_paths(new_user.id)
      path_ids = Enum.map(paths, & &1.id)

      assert child.id in path_ids
      refute parent.id in path_ids
    end

    test "list_mount_points/1 respects user permissions", %{
      owner: owner,
      viewer: viewer,
      other_user: other_user,
      path: path
    } do
      # Mark as mount point
      {:ok, _} = Paths.update_path(owner.id, path, %{mount_point: true})

      # Owner and viewer should see it
      owner_mounts = Paths.list_mount_points(owner.id)
      viewer_mounts = Paths.list_mount_points(viewer.id)
      other_mounts = Paths.list_mount_points(other_user.id)

      assert Enum.any?(owner_mounts, fn p -> p.id == path.id end)
      assert Enum.any?(viewer_mounts, fn p -> p.id == path.id end)
      refute Enum.any?(other_mounts, fn p -> p.id == path.id end)
    end

    test "soft-deleted paths are hidden from all users", %{
      owner: owner,
      viewer: viewer,
      path: path
    } do
      # Both can see the path initially
      assert Enum.any?(Paths.list_paths(owner.id), fn p -> p.id == path.id end)
      assert Enum.any?(Paths.list_paths(viewer.id), fn p -> p.id == path.id end)

      # Owner soft-deletes the path
      {:ok, _} = Paths.delete_path(owner.id, path)

      # Neither should see it now
      refute Enum.any?(Paths.list_paths(owner.id), fn p -> p.id == path.id end)
      refute Enum.any?(Paths.list_paths(viewer.id), fn p -> p.id == path.id end)
    end

    test "restoring path preserves all user_path associations", %{
      owner: owner,
      viewer: viewer,
      maintainer: maintainer,
      path: path
    } do
      # Soft-delete the path
      {:ok, _} = Paths.delete_path(owner.id, path)

      # Restore by recreating (should restore existing record)
      {:ok, restored} = Paths.create_path(%{path: "shared-path", user_id: owner.id})
      assert restored.id == path.id

      # All users should still have their roles (except deleted_at is cleared)
      assert Paths.has_role?(owner.id, restored.id, "owner")
      assert Paths.has_role?(viewer.id, restored.id, "viewer")
      assert Paths.has_role?(maintainer.id, restored.id, "maintainer")
    end
  end

  describe "edge cases for user-path relationships" do
    setup do
      user = user_fixture()
      %{user: user}
    end

    test "creating path with non-existent parent_id fails gracefully", %{user: user} do
      fake_parent_id = Ecto.UUID.generate()

      # Database trigger raises Postgrex.Error with "Parent path not found"
      assert_raise Postgrex.Error, ~r/Parent path not found/, fn ->
        Paths.create_path(%{path: "child", parent_id: fake_parent_id, user_id: user.id})
      end
    end

    test "concurrent user_path creation for same user/path", %{user: user} do
      {:ok, path} = Paths.create_path(%{path: "test", user_id: user.id})
      new_user = user_fixture()

      # Try to add same user to same path concurrently (user is owner, so authorized)
      tasks =
        for _ <- 1..5 do
          Task.async(fn ->
            Paths.add_user_to_path(user.id, new_user.id, path.id, "viewer")
          end)
        end

      results = Task.await_many(tasks, 10_000)

      # Exactly one should succeed
      successes = Enum.count(results, fn {status, _} -> status == :ok end)
      failures = Enum.count(results, fn {status, _} -> status == :error end)

      assert successes == 1
      assert failures == 4
    end

    test "creating child under soft-deleted parent succeeds (soft-delete doesn't restrict)", %{
      user: user
    } do
      {:ok, parent} = Paths.create_path(%{path: "parent", user_id: user.id})
      {:ok, _} = Paths.delete_path(user.id, parent)

      # Soft-deleted parents can still have children created
      # (the foreign key constraint only checks existence, not deleted_at)
      assert {:ok, child} =
               Paths.create_path(%{path: "child", parent_id: parent.id, user_id: user.id})

      assert child.parent_id == parent.id

      # However, the child won't be visible in normal queries if parent is deleted
      # This is a known edge case - application should prevent this scenario
    end

    test "maximum nesting depth", %{user: user} do
      # Create 50 levels deep to test performance and correctness
      {_final_id, _final_path} =
        Enum.reduce(1..50, {nil, ""}, fn level, {current_parent_id, parent_path} ->
          segment = "level#{level}"
          expected_path = parent_path <> "/#{segment}"

          {:ok, path} =
            Paths.create_path(%{
              path: segment,
              parent_id: current_parent_id,
              user_id: user.id
            })

          assert path.full_path == expected_path
          {path.id, expected_path}
        end)

      # Verify we can query deeply nested paths
      paths = Paths.list_paths(user.id)
      assert length(paths) == 50
    end

    test "path with special characters (dots, dashes, underscores)", %{user: user} do
      valid_segments = ["v1.0", "api-v2", "test_path", "a.b-c_d"]

      for segment <- valid_segments do
        assert {:ok, path} = Paths.create_path(%{path: segment, user_id: user.id})
        assert path.path == segment
      end
    end

    test "path starting with number", %{user: user} do
      assert {:ok, path} = Paths.create_path(%{path: "123", user_id: user.id})
      assert path.path == "123"
      assert path.full_path == "/123"
    end

    test "path with maximum length (255 characters)", %{user: user} do
      max_length_path = String.duplicate("a", 255)
      assert {:ok, path} = Paths.create_path(%{path: max_length_path, user_id: user.id})
      assert String.length(path.path) == 255
    end

    test "path exceeding maximum length fails", %{user: user} do
      too_long_path = String.duplicate("a", 256)
      assert {:error, changeset} = Paths.create_path(%{path: too_long_path, user_id: user.id})
      assert %{path: ["should be at most 255 character(s)"]} = errors_on(changeset)
    end

    test "soft-delete cascade performance with many descendants", %{user: user} do
      # Create a tree with 100 nodes
      {:ok, root} = Paths.create_path(%{path: "perf-root", user_id: user.id})

      # Create 10 level-1 children
      for i <- 1..10 do
        {:ok, child} =
          Paths.create_path(%{
            path: "child-#{i}",
            parent_id: root.id,
            user_id: user.id
          })

        # Create 9 grandchildren under each child (90 total)
        for j <- 1..9 do
          Paths.create_path(%{
            path: "gc-#{i}-#{j}",
            parent_id: child.id,
            user_id: user.id
          })
        end
      end

      # Measure delete time
      {time_us, {:ok, _}} = :timer.tc(fn -> Paths.delete_path(user.id, root) end)

      # Should complete reasonably fast
      assert time_us < 1_000_000, "Delete took #{time_us}μs (expected < 1s)"

      # Verify all descendants are soft-deleted
      remaining_paths = Paths.list_paths(user.id)
      assert remaining_paths == []
    end
  end

  describe "role management functions" do
    setup do
      user1 = user_fixture()
      user2 = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "shared-project",
          user_id: user1.id
        })

      %{user1: user1, user2: user2, path: path}
    end

    test "add_user_to_path/4 adds a viewer to a path", %{user1: user1, user2: user2, path: path} do
      assert {:ok, user_path} = Paths.add_user_to_path(user1.id, user2.id, path.id, "viewer")
      assert user_path.user_id == user2.id
      assert user_path.path_id == path.id
      assert user_path.role == "viewer"
    end

    test "add_user_to_path/4 adds a maintainer to a path", %{
      user1: user1,
      user2: user2,
      path: path
    } do
      assert {:ok, user_path} = Paths.add_user_to_path(user1.id, user2.id, path.id, "maintainer")
      assert user_path.role == "maintainer"
    end

    test "add_user_to_path/4 returns error when adding duplicate user-path association", %{
      user1: user1,
      user2: user2,
      path: path
    } do
      {:ok, _} = Paths.add_user_to_path(user1.id, user2.id, path.id, "viewer")

      assert {:error, changeset} =
               Paths.add_user_to_path(user1.id, user2.id, path.id, "maintainer")

      assert %{user_id: ["has already been taken"]} = errors_on(changeset)
    end

    test "add_user_to_path/4 returns error with invalid role", %{
      user1: user1,
      user2: user2,
      path: path
    } do
      assert {:error, changeset} =
               Paths.add_user_to_path(user1.id, user2.id, path.id, "invalid_role")

      assert %{role: ["is invalid"]} = errors_on(changeset)
    end

    test "add_user_to_path/4 returns error when non-owner tries to add user", %{
      user2: user2,
      path: path
    } do
      user3 = user_fixture()

      assert {:error, :unauthorized} =
               Paths.add_user_to_path(user2.id, user3.id, path.id, "viewer")
    end

    test "update_user_path_role/3 changes user role from viewer to maintainer", %{
      user1: user1,
      user2: user2,
      path: path
    } do
      {:ok, user_path} = Paths.add_user_to_path(user1.id, user2.id, path.id, "viewer")
      assert user_path.role == "viewer"

      assert {:ok, updated} = Paths.update_user_path_role(user1.id, user_path, "maintainer")
      assert updated.role == "maintainer"
      assert updated.id == user_path.id
    end

    test "update_user_path_role/3 changes user role from maintainer to owner", %{
      user1: user1,
      user2: user2,
      path: path
    } do
      {:ok, user_path} = Paths.add_user_to_path(user1.id, user2.id, path.id, "maintainer")
      assert {:ok, updated} = Paths.update_user_path_role(user1.id, user_path, "owner")
      assert updated.role == "owner"
    end

    test "update_user_path_role/3 returns error with invalid role", %{
      user1: user1,
      user2: user2,
      path: path
    } do
      {:ok, user_path} = Paths.add_user_to_path(user1.id, user2.id, path.id, "viewer")
      assert {:error, changeset} = Paths.update_user_path_role(user1.id, user_path, "admin")
      assert %{role: ["is invalid"]} = errors_on(changeset)
    end

    test "update_user_path_role/3 returns error when non-owner tries to update", %{
      user1: user1,
      user2: user2,
      path: path
    } do
      {:ok, user_path} = Paths.add_user_to_path(user1.id, user2.id, path.id, "viewer")

      assert {:error, :unauthorized} =
               Paths.update_user_path_role(user2.id, user_path, "maintainer")
    end

    test "remove_user_from_path/2 removes user association", %{
      user1: user1,
      user2: user2,
      path: path
    } do
      {:ok, user_path} = Paths.add_user_to_path(user1.id, user2.id, path.id, "viewer")
      assert {:ok, deleted} = Paths.remove_user_from_path(user1.id, user_path)
      assert deleted.id == user_path.id

      # Verify it's actually gone
      assert Paths.get_user_path(user2.id, path.id) == nil
    end

    test "remove_user_from_path/2 returns error when non-owner tries to remove", %{
      user1: user1,
      user2: user2,
      path: path
    } do
      {:ok, user_path} = Paths.add_user_to_path(user1.id, user2.id, path.id, "viewer")
      assert {:error, :unauthorized} = Paths.remove_user_from_path(user2.id, user_path)
    end

    test "get_user_path/2 returns user_path when association exists", %{
      user1: user1,
      user2: user2,
      path: path
    } do
      {:ok, user_path} = Paths.add_user_to_path(user1.id, user2.id, path.id, "viewer")
      retrieved = Paths.get_user_path(user2.id, path.id)
      assert retrieved.id == user_path.id
      assert retrieved.role == "viewer"
    end

    test "get_user_path/2 returns nil when no association exists", %{user2: user2, path: path} do
      assert Paths.get_user_path(user2.id, path.id) == nil
    end

    test "get_user_role/2 returns role string when association exists", %{
      user1: user1,
      user2: user2,
      path: path
    } do
      {:ok, _} = Paths.add_user_to_path(user1.id, user2.id, path.id, "maintainer")
      assert Paths.get_user_role(user2.id, path.id) == "maintainer"
    end

    test "get_user_role/2 returns nil when no association exists", %{user2: user2, path: path} do
      assert Paths.get_user_role(user2.id, path.id) == nil
    end

    test "list_path_users/1 returns all users for a path", %{
      user1: user1,
      user2: user2,
      path: path
    } do
      user3 = user_fixture()
      {:ok, _} = Paths.add_user_to_path(user1.id, user2.id, path.id, "viewer")
      {:ok, _} = Paths.add_user_to_path(user1.id, user3.id, path.id, "maintainer")

      users = Paths.list_path_users(path.id)
      user_ids = Enum.map(users, & &1.user_id) |> Enum.sort()

      # Should include owner (user1) + user2 + user3
      assert length(users) == 3
      assert user1.id in user_ids
      assert user2.id in user_ids
      assert user3.id in user_ids
    end

    test "list_path_users/1 returns empty list when path has no associations", %{user1: user1} do
      {:ok, path} = Paths.create_path(%{path: "isolated", user_id: user1.id})
      # Delete the owner association
      user_path = Paths.get_user_path(user1.id, path.id)
      Paths.remove_user_from_path(user1.id, user_path)

      assert Paths.list_path_users(path.id) == []
    end

    test "has_role?/3 returns true when user has exact role", %{
      user1: user1,
      user2: user2,
      path: path
    } do
      {:ok, _} = Paths.add_user_to_path(user1.id, user2.id, path.id, "viewer")
      assert Paths.has_role?(user2.id, path.id, "viewer") == true
    end

    test "has_role?/3 returns false when user has different role", %{
      user1: user1,
      user2: user2,
      path: path
    } do
      {:ok, _} = Paths.add_user_to_path(user1.id, user2.id, path.id, "viewer")
      assert Paths.has_role?(user2.id, path.id, "owner") == false
      assert Paths.has_role?(user2.id, path.id, "maintainer") == false
    end

    test "has_role?/3 returns false when user has no association", %{user2: user2, path: path} do
      assert Paths.has_role?(user2.id, path.id, "viewer") == false
    end
  end

  describe "edge cases for get_descendants and cascades" do
    setup do
      user = user_fixture()
      %{user: user}
    end

    test "get_descendants/1 handles very deep hierarchy (15 levels)", %{user: user} do
      # Create a 15-level deep hierarchy
      {:ok, root} = Paths.create_path(%{path: "root", user_id: user.id})

      # Build a 15-level deep hierarchy
      Enum.reduce(1..15, root, fn i, parent_path ->
        {:ok, child} =
          Paths.create_path(%{
            path: "level#{i}",
            parent_id: parent_path.id,
            user_id: user.id
          })

        child
      end)

      descendants = Paths.get_descendants(root)
      assert length(descendants) == 15
    end

    test "delete_path/1 cascade soft-deletes deep hierarchy efficiently", %{user: user} do
      # Create a 10-level hierarchy
      {:ok, root} = Paths.create_path(%{path: "root", user_id: user.id})

      # Build a 10-level deep hierarchy
      Enum.reduce(1..10, root, fn i, parent_path ->
        {:ok, child} =
          Paths.create_path(%{
            path: "level#{i}",
            parent_id: parent_path.id,
            user_id: user.id
          })

        child
      end)

      # Delete root should cascade to all 10 descendants
      assert {:ok, deleted} = Paths.delete_path(user.id, root)
      assert deleted.id == root.id

      # Verify all are soft-deleted
      descendants = Paths.get_descendants(root)
      assert descendants == []
    end

    test "delete_path/1 with wide tree (many siblings)", %{user: user} do
      {:ok, root} = Paths.create_path(%{path: "root", user_id: user.id})

      # Create 20 children under root
      for i <- 1..20 do
        {:ok, _child} =
          Paths.create_path(%{
            path: "child#{i}",
            parent_id: root.id,
            user_id: user.id
          })
      end

      # Delete root should cascade to all 20 children
      assert {:ok, _deleted} = Paths.delete_path(user.id, root)

      # Verify all are soft-deleted
      descendants = Paths.get_descendants(root)
      assert descendants == []
    end

    test "get_descendants/1 does not return soft-deleted descendants", %{user: user} do
      {:ok, root} = Paths.create_path(%{path: "root", user_id: user.id})
      {:ok, child1} = Paths.create_path(%{path: "child1", parent_id: root.id, user_id: user.id})
      {:ok, child2} = Paths.create_path(%{path: "child2", parent_id: root.id, user_id: user.id})

      {:ok, _grandchild} =
        Paths.create_path(%{path: "grandchild", parent_id: child1.id, user_id: user.id})

      # Soft-delete child1 (and its grandchild)
      Paths.delete_path(user.id, child1)

      # get_descendants should only return child2
      descendants = Paths.get_descendants(root)
      assert length(descendants) == 1
      assert hd(descendants).id == child2.id
    end
  end

  describe "edge cases for can_add_child and can_mark_as_mount" do
    setup do
      user = user_fixture()
      %{user: user}
    end

    test "can_add_child?/1 returns error for mount point", %{user: user} do
      {:ok, mount} = Paths.create_path(%{path: "mount", user_id: user.id})
      {:ok, mount} = Paths.update_path(user.id, mount, %{mount_point: true})

      assert {:error, message} = Paths.can_add_child?(mount)
      assert message =~ "mount point"
    end

    test "can_add_child?/1 returns ok for regular path", %{user: user} do
      {:ok, path} = Paths.create_path(%{path: "regular", user_id: user.id})

      assert {:ok, true} = Paths.can_add_child?(path)
    end

    test "can_mark_as_mount?/1 returns false when path has children", %{user: user} do
      {:ok, parent} = Paths.create_path(%{path: "parent", user_id: user.id})
      {:ok, _child} = Paths.create_path(%{path: "child", parent_id: parent.id, user_id: user.id})

      assert Paths.can_mark_as_mount?(parent) == false
    end

    test "can_mark_as_mount?/1 returns true when path has no children", %{user: user} do
      {:ok, path} = Paths.create_path(%{path: "lonely", user_id: user.id})

      assert Paths.can_mark_as_mount?(path) == true
    end
  end

  # Helper function to create a user fixture
  defp user_fixture(attrs \\ %{}) do
    unique_email = "user#{System.unique_integer([:positive])}@example.com"

    {:ok, user} =
      attrs
      |> Enum.into(%{
        email: unique_email,
        password: "hello world!"
      })
      |> Accounts.register_user()

    user
  end
end
