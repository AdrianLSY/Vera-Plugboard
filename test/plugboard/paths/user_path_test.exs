defmodule Plugboard.Paths.UserPathTest do
  use Plugboard.DataCase

  alias Plugboard.Paths
  alias Plugboard.Paths.UserPath
  alias Plugboard.Accounts

  describe "add_user_to_path/4" do
    setup do
      user = user_fixture()
      {:ok, path} = Paths.create_path(%{path: "test-path", user_id: user.id})
      %{user: user, path: path}
    end

    test "associates user with path with owner role", %{user: user, path: path} do
      new_user = user_fixture()

      assert {:ok, %UserPath{} = user_path} =
               Paths.add_user_to_path(user.id, new_user.id, path.id, "owner")

      assert user_path.user_id == new_user.id
      assert user_path.path_id == path.id
      assert user_path.role == "owner"
      assert user_path.inserted_at
      assert user_path.updated_at
    end

    test "associates user with path with maintainer role", %{user: user, path: path} do
      new_user = user_fixture()

      assert {:ok, %UserPath{} = user_path} =
               Paths.add_user_to_path(user.id, new_user.id, path.id, "maintainer")

      assert user_path.role == "maintainer"
    end

    test "associates user with path with viewer role", %{user: user, path: path} do
      new_user = user_fixture()

      assert {:ok, %UserPath{} = user_path} =
               Paths.add_user_to_path(user.id, new_user.id, path.id, "viewer")

      assert user_path.role == "viewer"
    end

    test "returns error for invalid role", %{user: user, path: path} do
      new_user = user_fixture()

      assert {:error, changeset} = Paths.add_user_to_path(user.id, new_user.id, path.id, "admin")
      assert "is invalid" in errors_on(changeset).role
    end

    test "returns error for empty role", %{user: user, path: path} do
      new_user = user_fixture()

      assert {:error, changeset} = Paths.add_user_to_path(user.id, new_user.id, path.id, "")
      errors = errors_on(changeset)
      assert "can't be blank" in errors.role or "is invalid" in errors.role
    end

    test "returns error for nil role", %{user: user, path: path} do
      new_user = user_fixture()

      assert {:error, changeset} = Paths.add_user_to_path(user.id, new_user.id, path.id, nil)
      errors = errors_on(changeset)
      assert "can't be blank" in errors.role
    end

    test "returns error for non-existent user", %{user: user, path: path} do
      fake_user_id = Ecto.UUID.generate()

      assert {:error, changeset} =
               Paths.add_user_to_path(user.id, fake_user_id, path.id, "viewer")

      assert %{user_id: ["does not exist"]} = errors_on(changeset)
    end

    test "returns error for non-existent path", %{user: user} do
      fake_path_id = Ecto.UUID.generate()
      new_user = user_fixture()

      # Returns :unauthorized because the acting user cannot be an owner of a non-existent path
      assert {:error, :unauthorized} =
               Paths.add_user_to_path(user.id, new_user.id, fake_path_id, "viewer")
    end

    test "prevents duplicate user-path associations", %{user: user, path: path} do
      new_user = user_fixture()

      # First association succeeds
      assert {:ok, _} = Paths.add_user_to_path(user.id, new_user.id, path.id, "viewer")

      # Duplicate association fails
      assert {:error, changeset} = Paths.add_user_to_path(user.id, new_user.id, path.id, "owner")

      errors = errors_on(changeset)
      # Either user_id or path_id should show "has already been taken"
      assert (errors[:user_id] && "has already been taken" in errors[:user_id]) or
               (errors[:path_id] && "has already been taken" in errors[:path_id])
    end

    test "allows same user to have different roles on different paths", %{user: user} do
      new_user = user_fixture()
      {:ok, path1} = Paths.create_path(%{path: "path1", user_id: user.id})
      {:ok, path2} = Paths.create_path(%{path: "path2", user_id: user.id})

      assert {:ok, user_path1} = Paths.add_user_to_path(user.id, new_user.id, path1.id, "viewer")
      assert {:ok, user_path2} = Paths.add_user_to_path(user.id, new_user.id, path2.id, "owner")

      assert user_path1.role == "viewer"
      assert user_path2.role == "owner"
    end

    test "allows multiple users to have same role on same path", %{user: user, path: path} do
      user1 = user_fixture()
      user2 = user_fixture()

      assert {:ok, _} = Paths.add_user_to_path(user.id, user1.id, path.id, "viewer")
      assert {:ok, _} = Paths.add_user_to_path(user.id, user2.id, path.id, "viewer")

      # Both should have access
      assert Paths.has_role?(user1.id, path.id, "viewer")
      assert Paths.has_role?(user2.id, path.id, "viewer")
    end
  end

  describe "update_user_path_role/3" do
    setup do
      user = user_fixture()
      {:ok, path} = Paths.create_path(%{path: "test-path", user_id: user.id})
      new_user = user_fixture()
      {:ok, user_path} = Paths.add_user_to_path(user.id, new_user.id, path.id, "viewer")
      %{user: user, path: path, user_path: user_path, new_user: new_user}
    end

    test "updates role from viewer to maintainer", %{
      user: user,
      user_path: user_path,
      new_user: new_user,
      path: path
    } do
      assert {:ok, updated} = Paths.update_user_path_role(user.id, user_path, "maintainer")
      assert updated.role == "maintainer"

      # Verify in database
      assert Paths.has_role?(new_user.id, path.id, "maintainer")
      refute Paths.has_role?(new_user.id, path.id, "viewer")
    end

    test "updates role from maintainer to owner", %{
      user: user,
      user_path: user_path,
      new_user: new_user,
      path: path
    } do
      {:ok, user_path} = Paths.update_user_path_role(user.id, user_path, "maintainer")
      assert {:ok, updated} = Paths.update_user_path_role(user.id, user_path, "owner")
      assert updated.role == "owner"

      # Verify in database
      assert Paths.has_role?(new_user.id, path.id, "owner")
    end

    test "updates role from owner to viewer", %{user: user, user_path: user_path} do
      {:ok, user_path} = Paths.update_user_path_role(user.id, user_path, "owner")
      assert {:ok, updated} = Paths.update_user_path_role(user.id, user_path, "viewer")
      assert updated.role == "viewer"
    end

    test "returns error for invalid role", %{user: user, user_path: user_path} do
      assert {:error, changeset} = Paths.update_user_path_role(user.id, user_path, "admin")
      assert "is invalid" in errors_on(changeset).role
    end

    test "returns error for nil role", %{user: user, user_path: user_path} do
      assert {:error, changeset} = Paths.update_user_path_role(user.id, user_path, nil)
      assert "can't be blank" in errors_on(changeset).role
    end

    test "returns error for empty role", %{user: user, user_path: user_path} do
      assert {:error, changeset} = Paths.update_user_path_role(user.id, user_path, "")
      errors = errors_on(changeset)
      assert "can't be blank" in errors.role or "is invalid" in errors.role
    end

    test "updates updated_at timestamp", %{user: user, user_path: user_path} do
      # Force a timestamp difference by manually setting the original to the past
      past_time = DateTime.add(DateTime.utc_now(), -2, :second) |> DateTime.truncate(:second)

      user_path_with_old_time =
        user_path
        |> Ecto.Changeset.change(updated_at: past_time)
        |> Repo.update!()

      {:ok, updated} = Paths.update_user_path_role(user.id, user_path_with_old_time, "maintainer")

      assert DateTime.compare(updated.updated_at, past_time) == :gt
    end
  end

  describe "remove_user_from_path/2" do
    setup do
      user = user_fixture()
      {:ok, path} = Paths.create_path(%{path: "test-path", user_id: user.id})
      new_user = user_fixture()
      {:ok, user_path} = Paths.add_user_to_path(user.id, new_user.id, path.id, "viewer")
      %{user: user, path: path, user_path: user_path, new_user: new_user}
    end

    test "removes user-path association", %{
      user: user,
      user_path: user_path,
      new_user: new_user,
      path: path
    } do
      assert {:ok, _} = Paths.remove_user_from_path(user.id, user_path)

      # Verify user no longer has access
      refute Paths.has_role?(new_user.id, path.id, "viewer")
      assert is_nil(Paths.get_user_path(new_user.id, path.id))
    end

    test "allows path to be re-associated after removal", %{
      user: user,
      user_path: user_path,
      new_user: new_user,
      path: path
    } do
      assert {:ok, _} = Paths.remove_user_from_path(user.id, user_path)

      # Re-associate with different role
      assert {:ok, new_user_path} = Paths.add_user_to_path(user.id, new_user.id, path.id, "owner")
      assert new_user_path.role == "owner"
    end

    test "does not affect other users' access to the same path", %{user: user, path: path} do
      user2 = user_fixture()
      user3 = user_fixture()

      {:ok, user_path2} = Paths.add_user_to_path(user.id, user2.id, path.id, "viewer")
      {:ok, _user_path3} = Paths.add_user_to_path(user.id, user3.id, path.id, "maintainer")

      # Remove user2
      assert {:ok, _} = Paths.remove_user_from_path(user.id, user_path2)

      # user3 should still have access
      assert Paths.has_role?(user3.id, path.id, "maintainer")
    end

    test "path remains accessible to other users after one user removed", %{
      user: owner,
      path: path,
      user_path: user_path
    } do
      # Remove the viewer
      {:ok, _} = Paths.remove_user_from_path(owner.id, user_path)

      # Owner should still have access
      paths = Paths.list_paths(owner.id)
      assert Enum.any?(paths, fn p -> p.id == path.id end)
    end
  end

  describe "get_user_path/2" do
    setup do
      user = user_fixture()
      {:ok, path} = Paths.create_path(%{path: "test-path", user_id: user.id})
      new_user = user_fixture()
      {:ok, user_path} = Paths.add_user_to_path(user.id, new_user.id, path.id, "viewer")
      %{user: user, path: path, user_path: user_path, new_user: new_user}
    end

    test "returns user_path when association exists", %{
      new_user: new_user,
      path: path,
      user_path: original
    } do
      user_path = Paths.get_user_path(new_user.id, path.id)
      assert user_path.id == original.id
      assert user_path.role == "viewer"
    end

    test "returns nil when association does not exist", %{path: path} do
      other_user = user_fixture()
      assert is_nil(Paths.get_user_path(other_user.id, path.id))
    end

    test "returns nil for non-existent user", %{path: path} do
      fake_user_id = Ecto.UUID.generate()
      assert is_nil(Paths.get_user_path(fake_user_id, path.id))
    end

    test "returns nil for non-existent path", %{new_user: new_user} do
      fake_path_id = Ecto.UUID.generate()
      assert is_nil(Paths.get_user_path(new_user.id, fake_path_id))
    end
  end

  describe "list_path_users/1" do
    setup do
      user = user_fixture()
      {:ok, path} = Paths.create_path(%{path: "test-path", user_id: user.id})
      %{user: user, path: path}
    end

    test "lists all users for a path", %{user: owner, path: path} do
      user1 = user_fixture()
      user2 = user_fixture()
      user3 = user_fixture()

      Paths.add_user_to_path(owner.id, user1.id, path.id, "viewer")
      Paths.add_user_to_path(owner.id, user2.id, path.id, "maintainer")
      Paths.add_user_to_path(owner.id, user3.id, path.id, "viewer")

      user_paths = Paths.list_path_users(path.id)

      # Should include owner + 3 added users = 4 total
      assert length(user_paths) == 4

      # Verify all users are included
      user_ids = Enum.map(user_paths, & &1.user_id)
      assert owner.id in user_ids
      assert user1.id in user_ids
      assert user2.id in user_ids
      assert user3.id in user_ids
    end

    test "includes role information", %{user: user, path: path} do
      user1 = user_fixture()
      user2 = user_fixture()

      Paths.add_user_to_path(user.id, user1.id, path.id, "viewer")
      Paths.add_user_to_path(user.id, user2.id, path.id, "maintainer")

      user_paths = Paths.list_path_users(path.id)

      viewer = Enum.find(user_paths, fn up -> up.user_id == user1.id end)
      maintainer = Enum.find(user_paths, fn up -> up.user_id == user2.id end)

      assert viewer.role == "viewer"
      assert maintainer.role == "maintainer"
    end

    test "preloads user data", %{user: user, path: path} do
      user1 = user_fixture()
      Paths.add_user_to_path(user.id, user1.id, path.id, "viewer")

      user_paths = Paths.list_path_users(path.id)

      # Verify user association is preloaded
      assert Enum.all?(user_paths, fn up ->
               Ecto.assoc_loaded?(up.user) and up.user.email != nil
             end)
    end

    test "returns empty list for path with no users", %{user: owner, path: path} do
      # Remove owner association
      user_path = Paths.get_user_path(owner.id, path.id)
      Paths.remove_user_from_path(owner.id, user_path)

      user_paths = Paths.list_path_users(path.id)
      assert user_paths == []
    end

    test "returns empty list for non-existent path" do
      fake_path_id = Ecto.UUID.generate()
      user_paths = Paths.list_path_users(fake_path_id)
      assert user_paths == []
    end
  end

  describe "has_role?/3" do
    setup do
      user = user_fixture()
      {:ok, path} = Paths.create_path(%{path: "test-path", user_id: user.id})
      new_user = user_fixture()
      {:ok, _user_path} = Paths.add_user_to_path(user.id, new_user.id, path.id, "viewer")
      %{user: user, path: path, new_user: new_user}
    end

    test "returns true when user has exact role", %{new_user: new_user, path: path} do
      assert Paths.has_role?(new_user.id, path.id, "viewer")
    end

    test "returns false when user has different role", %{new_user: new_user, path: path} do
      refute Paths.has_role?(new_user.id, path.id, "owner")
      refute Paths.has_role?(new_user.id, path.id, "maintainer")
    end

    test "returns false when user has no association", %{path: path} do
      other_user = user_fixture()
      refute Paths.has_role?(other_user.id, path.id, "viewer")
      refute Paths.has_role?(other_user.id, path.id, "owner")
    end

    test "returns false for non-existent user", %{path: path} do
      fake_user_id = Ecto.UUID.generate()
      refute Paths.has_role?(fake_user_id, path.id, "viewer")
    end

    test "returns false for non-existent path", %{new_user: new_user} do
      fake_path_id = Ecto.UUID.generate()
      refute Paths.has_role?(new_user.id, fake_path_id, "viewer")
    end

    test "returns true for owner role", %{user: owner, path: path} do
      assert Paths.has_role?(owner.id, path.id, "owner")
    end
  end

  describe "cascade delete behavior" do
    test "deleting user cascades to user_paths" do
      user = user_fixture()
      {:ok, path} = Paths.create_path(%{path: "test-path", user_id: user.id})
      viewer = user_fixture()
      {:ok, user_path} = Paths.add_user_to_path(user.id, viewer.id, path.id, "viewer")

      # Delete the viewer user
      Repo.delete!(viewer)

      # user_path should be deleted
      assert is_nil(Repo.get(UserPath, user_path.id))
    end

    test "deleting path cascades to user_paths" do
      user = user_fixture()
      {:ok, path} = Paths.create_path(%{path: "test-path", user_id: user.id})
      viewer = user_fixture()
      {:ok, user_path} = Paths.add_user_to_path(user.id, viewer.id, path.id, "viewer")

      # Hard delete the path (bypass soft-delete)
      Repo.delete!(path)

      # user_path should be deleted
      assert is_nil(Repo.get(UserPath, user_path.id))
    end

    test "soft-deleting path does not cascade to user_paths" do
      user = user_fixture()
      {:ok, path} = Paths.create_path(%{path: "test-path", user_id: user.id})
      viewer = user_fixture()
      {:ok, user_path} = Paths.add_user_to_path(user.id, viewer.id, path.id, "viewer")

      # Soft-delete the path
      Paths.delete_path(user.id, path)

      # user_path should still exist
      assert Repo.get(UserPath, user_path.id)

      # But user should not see the path in their list
      paths = Paths.list_paths(viewer.id)
      refute Enum.any?(paths, fn p -> p.id == path.id end)
    end
  end

  describe "UserPath changeset validation" do
    test "valid changeset with all required fields" do
      user = user_fixture()
      {:ok, path} = Paths.create_path(%{path: "test", user_id: user.id})

      changeset =
        UserPath.changeset(%UserPath{}, %{
          user_id: user.id,
          path_id: path.id,
          role: "viewer"
        })

      assert changeset.valid?
    end

    test "invalid changeset without user_id" do
      user = user_fixture()
      {:ok, path} = Paths.create_path(%{path: "test", user_id: user.id})

      changeset =
        UserPath.changeset(%UserPath{}, %{
          path_id: path.id,
          role: "viewer"
        })

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).user_id
    end

    test "invalid changeset without path_id" do
      user = user_fixture()

      changeset =
        UserPath.changeset(%UserPath{}, %{
          user_id: user.id,
          role: "viewer"
        })

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).path_id
    end

    test "invalid changeset without role" do
      user = user_fixture()
      {:ok, path} = Paths.create_path(%{path: "test", user_id: user.id})

      changeset =
        UserPath.changeset(%UserPath{}, %{
          user_id: user.id,
          path_id: path.id
        })

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).role
    end

    test "valid_roles/0 returns correct list" do
      assert UserPath.valid_roles() == ~w(owner maintainer viewer)
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
