defmodule Plugboard.PathsTest do
  use Plugboard.DataCase

  alias Plugboard.Paths
  alias Plugboard.Paths.Path
  alias Plugboard.Accounts

  describe "list_paths/1" do
    setup do
      user = user_fixture()
      %{user: user}
    end

    test "returns all active paths for a user", %{user: user} do
      {:ok, path1} =
        Paths.create_path(%{
          path: "xyz",
          user_id: user.id,
          created_by_user_id: user.id
        })

      {:ok, path2} =
        Paths.create_path(%{
          path: "abc",
          user_id: user.id,
          created_by_user_id: user.id
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
          user_id: user.id,
          created_by_user_id: user.id
        })

      {:ok, _deleted} = Paths.delete_path(path)

      paths = Paths.list_paths(user.id)
      assert paths == []
    end

    test "does not return paths from other users", %{user: user} do
      other_user = user_fixture()

      {:ok, _path} =
        Paths.create_path(%{
          path: "xyz",
          user_id: other_user.id,
          created_by_user_id: other_user.id
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
          user_id: user.id,
          created_by_user_id: user.id
        })

      {:ok, mount_point} =
        Paths.create_path(%{
          path: "abc",
          user_id: user.id,
          created_by_user_id: user.id,
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
        user_id: user.id,
        created_by_user_id: user.id
      }

      assert {:ok, %Path{} = path} = Paths.create_path(attrs)
      assert path.path == "xyz"
      assert path.full_path == "/xyz"
      assert path.user_id == user.id
      assert path.created_by_user_id == user.id
      assert path.mount_point == false
      assert is_nil(path.parent_id)
      assert is_nil(path.deleted_at)
    end

    test "creates a child path with valid data", %{user: user} do
      {:ok, parent} =
        Paths.create_path(%{
          path: "xyz",
          user_id: user.id,
          created_by_user_id: user.id
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
          user_id: user.id,
          created_by_user_id: user.id
        })

      {:ok, level2} =
        Paths.create_path(%{
          path: "b",
          parent_id: level1.id,
          user_id: user.id,
          created_by_user_id: user.id
        })

      {:ok, level3} =
        Paths.create_path(%{
          path: "c",
          parent_id: level2.id,
          user_id: user.id,
          created_by_user_id: user.id
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
      assert "can't be blank" in errors.created_by_user_id
    end

    test "enforces unique sibling paths", %{user: user} do
      {:ok, _path1} =
        Paths.create_path(%{
          path: "xyz",
          user_id: user.id,
          created_by_user_id: user.id
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
          user_id: user.id,
          created_by_user_id: user.id
        })

      {:ok, parent2} =
        Paths.create_path(%{
          path: "parent2",
          user_id: user.id,
          created_by_user_id: user.id
        })

      {:ok, child1} =
        Paths.create_path(%{
          path: "child",
          parent_id: parent1.id,
          user_id: user.id,
          created_by_user_id: user.id
        })

      {:ok, child2} =
        Paths.create_path(%{
          path: "child",
          parent_id: parent2.id,
          user_id: user.id,
          created_by_user_id: user.id
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
          created_by_user_id: user.id,
          mount_point: true
        })

      original_id = original.id
      {:ok, deleted} = Paths.delete_path(original)
      assert deleted.deleted_at != nil

      # Attempt to create the same path again
      {:ok, restored} =
        Paths.create_path(%{
          path: "xyz",
          user_id: user.id,
          created_by_user_id: user.id
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
          user_id: user.id,
          created_by_user_id: user.id
        })

      {:ok, child} =
        Paths.create_path(%{
          path: "child",
          parent_id: parent.id,
          user_id: user.id,
          created_by_user_id: user.id
        })

      child_id = child.id
      {:ok, _deleted} = Paths.delete_path(child)

      # Recreate the child
      {:ok, restored} =
        Paths.create_path(%{
          path: "child",
          parent_id: parent.id,
          user_id: user.id,
          created_by_user_id: user.id
        })

      assert restored.id == child_id
      assert is_nil(restored.deleted_at)
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
          created_by_user_id: user.id,
          mount_point: true
        })

      # Attempt to create a child under the mount point
      assert_raise Postgrex.Error, ~r/Cannot create child path under a mount point/, fn ->
        Paths.create_path(%{
          path: "child",
          parent_id: mount.id,
          user_id: user.id,
          created_by_user_id: user.id
        })
      end
    end

    test "prevents moving a path to become child of a mount point", %{user: user} do
      {:ok, mount} =
        Paths.create_path(%{
          path: "mount",
          user_id: user.id,
          created_by_user_id: user.id,
          mount_point: true
        })

      {:ok, regular_path} =
        Paths.create_path(%{
          path: "regular",
          user_id: user.id,
          created_by_user_id: user.id
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
          user_id: user.id,
          created_by_user_id: user.id
        })

      {:ok, _child} =
        Paths.create_path(%{
          path: "child",
          parent_id: parent.id,
          user_id: user.id,
          created_by_user_id: user.id
        })

      # Attempt to mark parent as mount point
      assert_raise Postgrex.Error, ~r/Cannot mark path as mount point when it has children/, fn ->
        Paths.update_path(parent, %{mount_point: true})
      end
    end

    test "allows marking path as mount when it has no children", %{user: user} do
      {:ok, path} =
        Paths.create_path(%{
          path: "path",
          user_id: user.id,
          created_by_user_id: user.id
        })

      assert {:ok, updated} = Paths.update_path(path, %{mount_point: true})
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
          user_id: user.id,
          created_by_user_id: user.id
        })

      assert {:ok, updated} = Paths.update_path(path, %{path: "abc"})
      assert updated.path == "abc"
      assert updated.full_path == "/abc"
    end

    test "updates mount_point flag", %{user: user} do
      {:ok, path} =
        Paths.create_path(%{
          path: "xyz",
          user_id: user.id,
          created_by_user_id: user.id,
          mount_point: false
        })

      assert {:ok, updated} = Paths.update_path(path, %{mount_point: true})
      assert updated.mount_point == true
    end

    test "updates full_path of descendants when path segment changes", %{user: user} do
      {:ok, parent} =
        Paths.create_path(%{
          path: "parent",
          user_id: user.id,
          created_by_user_id: user.id
        })

      {:ok, child} =
        Paths.create_path(%{
          path: "child",
          parent_id: parent.id,
          user_id: user.id,
          created_by_user_id: user.id
        })

      {:ok, grandchild} =
        Paths.create_path(%{
          path: "grandchild",
          parent_id: child.id,
          user_id: user.id,
          created_by_user_id: user.id
        })

      # Update parent path
      {:ok, _updated_parent} = Paths.update_path(parent, %{path: "newparent"})

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
          user_id: user.id,
          created_by_user_id: user.id
        })

      assert {:ok, deleted} = Paths.delete_path(path)
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
          user_id: user.id,
          created_by_user_id: user.id
        })

      {:ok, child} =
        Paths.create_path(%{
          path: "child",
          parent_id: parent.id,
          user_id: user.id,
          created_by_user_id: user.id
        })

      # Delete parent
      {:ok, _deleted} = Paths.delete_path(parent)

      # Child should also be deleted (cascade)
      assert is_nil(Paths.get_path(child.id))
    end

    test "cascade soft-deletes logs descendant count", %{user: user} do
      {:ok, parent} =
        Paths.create_path(%{
          path: "parent",
          user_id: user.id,
          created_by_user_id: user.id
        })

      {:ok, child1} =
        Paths.create_path(%{
          path: "child1",
          parent_id: parent.id,
          user_id: user.id,
          created_by_user_id: user.id
        })

      {:ok, _child2} =
        Paths.create_path(%{
          path: "child2",
          parent_id: parent.id,
          user_id: user.id,
          created_by_user_id: user.id
        })

      {:ok, _grandchild} =
        Paths.create_path(%{
          path: "grandchild",
          parent_id: child1.id,
          user_id: user.id,
          created_by_user_id: user.id
        })

      # Capture logs - temporarily set log level to info
      import ExUnit.CaptureLog
      old_level = Logger.level()
      Logger.configure(level: :info)

      log =
        capture_log(fn ->
          {:ok, _deleted} = Paths.delete_path(parent)
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
          user_id: user.id,
          created_by_user_id: user.id
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
          user_id: user.id,
          created_by_user_id: user.id
        })

      {:ok, _deleted} = Paths.delete_path(path)

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
          user_id: user.id,
          created_by_user_id: user.id
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
          user_id: user.id,
          created_by_user_id: user.id
        })

      assert Paths.can_mark_as_mount?(path) == true
    end

    test "returns error for path with children", %{user: user} do
      {:ok, parent} =
        Paths.create_path(%{
          path: "parent",
          user_id: user.id,
          created_by_user_id: user.id
        })

      {:ok, _child} =
        Paths.create_path(%{
          path: "child",
          parent_id: parent.id,
          user_id: user.id,
          created_by_user_id: user.id
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
          user_id: user.id,
          created_by_user_id: user.id
        })

      assert {:ok, true} = Paths.can_add_child?(path)
    end

    test "returns error for mount point", %{user: user} do
      {:ok, mount} =
        Paths.create_path(%{
          path: "mount",
          user_id: user.id,
          created_by_user_id: user.id,
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
          user_id: user.id,
          created_by_user_id: user.id
        })

      {:ok, child1} =
        Paths.create_path(%{
          path: "child1",
          parent_id: parent.id,
          user_id: user.id,
          created_by_user_id: user.id
        })

      {:ok, child2} =
        Paths.create_path(%{
          path: "child2",
          parent_id: parent.id,
          user_id: user.id,
          created_by_user_id: user.id
        })

      {:ok, _grandchild} =
        Paths.create_path(%{
          path: "grandchild",
          parent_id: child1.id,
          user_id: user.id,
          created_by_user_id: user.id
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
          user_id: user.id,
          created_by_user_id: user.id
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
          user_id: user.id,
          created_by_user_id: user.id
        })

      {:ok, child1} =
        Paths.create_path(%{
          path: "child1",
          parent_id: parent.id,
          user_id: user.id,
          created_by_user_id: user.id
        })

      {:ok, child2} =
        Paths.create_path(%{
          path: "child2",
          parent_id: parent.id,
          user_id: user.id,
          created_by_user_id: user.id
        })

      {:ok, grandchild1} =
        Paths.create_path(%{
          path: "grandchild1",
          parent_id: child1.id,
          user_id: user.id,
          created_by_user_id: user.id
        })

      {:ok, grandchild2} =
        Paths.create_path(%{
          path: "grandchild2",
          parent_id: child2.id,
          user_id: user.id,
          created_by_user_id: user.id
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
          user_id: user.id,
          created_by_user_id: user.id
        })

      assert Paths.get_descendants(path) == []
    end
  end

  describe "database CHECK constraints" do
    setup do
      user = user_fixture()
      %{user: user}
    end

    test "prevents paths with slashes at database level", %{user: user} do
      # Bypass application validation by using raw SQL
      {:ok, uuid_binary} = Ecto.UUID.dump(Ecto.UUID.generate())
      {:ok, user_id_binary} = Ecto.UUID.dump(user.id)

      assert_raise Postgrex.Error, ~r/path_no_slashes/, fn ->
        Repo.query!(
          "INSERT INTO paths (id, user_id, created_by_user_id, path, full_path, mount_point, inserted_at, updated_at)
           VALUES ($1, $2, $3, $4, $5, $6, NOW(), NOW())",
          [
            uuid_binary,
            user_id_binary,
            user_id_binary,
            "invalid/path",
            "/invalid/path",
            false
          ]
        )
      end
    end

    test "prevents paths with invalid characters at database level", %{user: user} do
      {:ok, uuid_binary} = Ecto.UUID.dump(Ecto.UUID.generate())
      {:ok, user_id_binary} = Ecto.UUID.dump(user.id)

      assert_raise Postgrex.Error, ~r/path_valid_chars/, fn ->
        Repo.query!(
          "INSERT INTO paths (id, user_id, created_by_user_id, path, full_path, mount_point, inserted_at, updated_at)
           VALUES ($1, $2, $3, $4, $5, $6, NOW(), NOW())",
          [
            uuid_binary,
            user_id_binary,
            user_id_binary,
            "invalid@path!",
            "/invalid@path!",
            false
          ]
        )
      end
    end

    test "prevents empty paths at database level", %{user: user} do
      {:ok, uuid_binary} = Ecto.UUID.dump(Ecto.UUID.generate())
      {:ok, user_id_binary} = Ecto.UUID.dump(user.id)

      assert_raise Postgrex.Error, ~r/path_length/, fn ->
        Repo.query!(
          "INSERT INTO paths (id, user_id, created_by_user_id, path, full_path, mount_point, inserted_at, updated_at)
           VALUES ($1, $2, $3, $4, $5, $6, NOW(), NOW())",
          [
            uuid_binary,
            user_id_binary,
            user_id_binary,
            "",
            "/",
            false
          ]
        )
      end
    end

    test "prevents paths longer than 255 characters at database level", %{user: user} do
      long_path = String.duplicate("a", 256)
      {:ok, uuid_binary} = Ecto.UUID.dump(Ecto.UUID.generate())
      {:ok, user_id_binary} = Ecto.UUID.dump(user.id)

      assert_raise Postgrex.Error, ~r/path_length/, fn ->
        Repo.query!(
          "INSERT INTO paths (id, user_id, created_by_user_id, path, full_path, mount_point, inserted_at, updated_at)
           VALUES ($1, $2, $3, $4, $5, $6, NOW(), NOW())",
          [
            uuid_binary,
            user_id_binary,
            user_id_binary,
            long_path,
            "/#{long_path}",
            false
          ]
        )
      end
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
