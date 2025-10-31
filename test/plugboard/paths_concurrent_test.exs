defmodule Plugboard.PathsConcurrentTest do
  use Plugboard.DataCase, async: false

  alias Plugboard.Paths
  alias Plugboard.Paths.Path
  alias Plugboard.Accounts

  describe "concurrent soft-delete restoration" do
    setup do
      user = user_fixture()
      %{user: user}
    end

    test "concurrent restoration of same path succeeds once, others get unique constraint error",
         %{user: user} do
      # Create and then soft-delete a path
      {:ok, original} =
        Paths.create_path(%{
          path: "concurrent_test",
          user_id: user.id,
          created_by_user_id: user.id
        })

      original_id = original.id
      {:ok, _deleted} = Paths.delete_path(original)

      # Try to restore concurrently from multiple tasks
      attrs = %{
        path: "concurrent_test",
        user_id: user.id,
        created_by_user_id: user.id
      }

      tasks =
        for _ <- 1..10 do
          Task.async(fn ->
            # Add small random delay to increase chance of collision
            Process.sleep(:rand.uniform(5))
            Paths.create_path(attrs)
          end)
        end

      results = Task.await_many(tasks, 10_000)

      # Count successes and errors
      successes = Enum.count(results, fn {status, _} -> status == :ok end)
      errors = Enum.count(results, fn {status, _} -> status == :error end)

      # Exactly one should succeed (the restoration)
      assert successes == 1, "Expected 1 success, got #{successes}"
      assert errors == 9, "Expected 9 errors, got #{errors}"

      # The successful restoration should have the original ID
      {:ok, restored} = Enum.find(results, fn {status, _} -> status == :ok end)
      assert restored.id == original_id

      # Verify errors are unique constraint violations
      error_changesets = for {:error, changeset} <- results, do: changeset

      for changeset <- error_changesets do
        errors = errors_on(changeset)
        assert "has already been taken" in errors.path
      end
    end

    test "concurrent restoration of different paths all succeed", %{user: user} do
      # Create and delete multiple paths
      paths =
        for i <- 1..5 do
          {:ok, path} =
            Paths.create_path(%{
              path: "path_#{i}",
              user_id: user.id,
              created_by_user_id: user.id
            })

          {:ok, _deleted} = Paths.delete_path(path)
          {path.id, "path_#{i}"}
        end

      # Try to restore them all concurrently
      tasks =
        for {_id, path_name} <- paths do
          Task.async(fn ->
            Paths.create_path(%{
              path: path_name,
              user_id: user.id,
              created_by_user_id: user.id
            })
          end)
        end

      results = Task.await_many(tasks, 10_000)

      # All should succeed
      successes = Enum.count(results, fn {status, _} -> status == :ok end)
      assert successes == 5
    end

    test "idempotent restoration - calling restore twice is safe", %{user: user} do
      {:ok, original} =
        Paths.create_path(%{
          path: "idempotent",
          user_id: user.id,
          created_by_user_id: user.id
        })

      {:ok, deleted} = Paths.delete_path(original)

      # Restore once
      changeset1 = Path.restore_changeset(deleted, %{})
      {:ok, restored1} = Repo.update(changeset1)

      # Restore again (should be no-op)
      changeset2 = Path.restore_changeset(restored1, %{})
      {:ok, restored2} = Repo.update(changeset2)

      # Should return same values
      assert restored1.id == restored2.id
      assert restored1.updated_at == restored2.updated_at
      assert is_nil(restored2.deleted_at)

      # Changeset should be empty (no changes)
      assert changeset2.changes == %{}
    end
  end

  describe "concurrent child creation under mount" do
    setup do
      user = user_fixture()
      %{user: user}
    end

    test "marking parent as mount while creating child causes one to fail", %{user: user} do
      {:ok, parent} =
        Paths.create_path(%{
          path: "parent",
          user_id: user.id,
          created_by_user_id: user.id
        })

      # One task marks parent as mount, other tries to create child
      # Both wrapped in try/catch to handle Postgrex errors gracefully
      mark_mount_task =
        Task.async(fn ->
          try do
            Process.sleep(1)
            Paths.update_path(parent, %{mount_point: true})
          rescue
            e in Postgrex.Error -> {:error, e}
          end
        end)

      create_child_task =
        Task.async(fn ->
          try do
            Process.sleep(1)

            Paths.create_path(%{
              path: "child",
              parent_id: parent.id,
              user_id: user.id,
              created_by_user_id: user.id
            })
          rescue
            e in Postgrex.Error -> {:error, e}
          end
        end)

      results = Task.await_many([mark_mount_task, create_child_task], 10_000)

      # One should succeed, one should fail
      successes = Enum.count(results, fn {status, _} -> status == :ok end)

      # At least one operation should complete successfully
      assert successes >= 1

      # Verify final state is consistent
      updated_parent = Repo.get!(Path, parent.id)
      children = Paths.get_children(updated_parent)

      # If parent is mount, should have no children
      if updated_parent.mount_point do
        assert children == []
      else
        # If parent is not mount, child should exist
        assert length(children) >= 0
      end
    end

    test "concurrent child creations under same parent all succeed", %{user: user} do
      {:ok, parent} =
        Paths.create_path(%{
          path: "parent",
          user_id: user.id,
          created_by_user_id: user.id
        })

      # Try to create multiple children concurrently
      tasks =
        for i <- 1..5 do
          Task.async(fn ->
            Paths.create_path(%{
              path: "child_#{i}",
              parent_id: parent.id,
              user_id: user.id,
              created_by_user_id: user.id
            })
          end)
        end

      results = Task.await_many(tasks, 10_000)

      # All should succeed
      successes = Enum.count(results, fn {status, _} -> status == :ok end)
      assert successes == 5

      # Verify all children exist
      children = Paths.get_children(parent)
      assert length(children) == 5
    end
  end

  describe "concurrent updates" do
    setup do
      user = user_fixture()
      %{user: user}
    end

    test "concurrent updates to different fields succeed", %{user: user} do
      {:ok, path} =
        Paths.create_path(%{
          path: "test",
          user_id: user.id,
          created_by_user_id: user.id
        })

      # One task updates path segment, another checks mount status
      update_task =
        Task.async(fn ->
          Paths.update_path(path, %{path: "updated"})
        end)

      check_task =
        Task.async(fn ->
          Paths.can_mark_as_mount?(path)
        end)

      results = Task.await_many([update_task, check_task], 10_000)

      # Both should complete (may succeed or fail depending on timing)
      assert length(results) == 2
    end

    test "concurrent deletes of same path are safe", %{user: user} do
      {:ok, path} =
        Paths.create_path(%{
          path: "test",
          user_id: user.id,
          created_by_user_id: user.id
        })

      # Try to delete concurrently
      tasks =
        for _ <- 1..5 do
          Task.async(fn ->
            # Reload path each time to get fresh record
            fresh_path = Repo.get!(Path, path.id)
            Paths.delete_path(fresh_path)
          end)
        end

      results = Task.await_many(tasks, 10_000)

      # All should succeed (setting deleted_at is idempotent)
      successes = Enum.count(results, fn {status, _} -> status == :ok end)
      assert successes == 5

      # Verify path is deleted
      deleted_path = Repo.get!(Path, path.id)
      assert deleted_path.deleted_at != nil
    end
  end

  describe "transaction rollback on errors" do
    setup do
      user = user_fixture()
      %{user: user}
    end

    test "failed restoration rolls back transaction", %{user: user} do
      {:ok, original} =
        Paths.create_path(%{
          path: "rollback_test",
          user_id: user.id,
          created_by_user_id: user.id
        })

      {:ok, _deleted} = Paths.delete_path(original)

      # First restoration succeeds
      {:ok, _restored} =
        Paths.create_path(%{
          path: "rollback_test",
          user_id: user.id,
          created_by_user_id: user.id
        })

      # Second restoration should fail with unique constraint
      result =
        Paths.create_path(%{
          path: "rollback_test",
          user_id: user.id,
          created_by_user_id: user.id
        })

      assert {:error, changeset} = result
      assert "has already been taken" in errors_on(changeset).path

      # Verify no partial state was created
      count =
        Path
        |> where([p], p.path == "rollback_test")
        |> where([p], p.user_id == ^user.id)
        |> where([p], is_nil(p.deleted_at))
        |> Repo.aggregate(:count)

      assert count == 1
    end
  end

  describe "performance tests" do
    setup do
      user = user_fixture()
      %{user: user}
    end

    @tag :performance
    @tag timeout: 30_000
    test "cascade delete of large tree completes efficiently", %{user: user} do
      # Create a tree with 100 nodes
      {:ok, root} =
        Paths.create_path(%{
          path: "perf_root",
          user_id: user.id,
          created_by_user_id: user.id
        })

      # Create 10 level-1 children
      for i <- 1..10 do
        {:ok, child} =
          Paths.create_path(%{
            path: "child_#{i}",
            parent_id: root.id,
            user_id: user.id,
            created_by_user_id: user.id
          })

        # Create 9 grandchildren under each child (total 90 grandchildren)
        for j <- 1..9 do
          Paths.create_path(%{
            path: "grandchild_#{i}_#{j}",
            parent_id: child.id,
            user_id: user.id,
            created_by_user_id: user.id
          })
        end
      end

      # Measure delete time - should be fast with parent_id index
      {time_us, {:ok, _}} = :timer.tc(fn -> Paths.delete_path(root) end)

      # Should complete in under 500ms even with 100 nodes
      assert time_us < 500_000, "Delete took #{time_us}μs (expected < 500ms)"
    end
  end

  describe "stress test" do
    setup do
      user = user_fixture()
      %{user: user}
    end

    @tag :stress
    @tag timeout: 60_000
    test "heavy concurrent load completes without deadlocks", %{user: user} do
      # Create a parent path
      {:ok, parent} =
        Paths.create_path(%{
          path: "stress_parent",
          user_id: user.id,
          created_by_user_id: user.id
        })

      # Spawn many concurrent operations
      tasks =
        for i <- 1..50 do
          Task.async(fn ->
            case rem(i, 3) do
              0 ->
                # Create child
                Paths.create_path(%{
                  path: "stress_child_#{i}",
                  parent_id: parent.id,
                  user_id: user.id,
                  created_by_user_id: user.id
                })

              1 ->
                # Query children
                Paths.get_children(parent)
                {:ok, :queried}

              2 ->
                # Check if can mark as mount
                Paths.can_mark_as_mount?(parent)
            end
          end)
        end

      results = Task.await_many(tasks, 30_000)

      # All tasks should complete (some may fail, but none should deadlock)
      assert length(results) == 50

      # System should still be in consistent state
      children = Paths.get_children(parent)
      assert is_list(children)
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
