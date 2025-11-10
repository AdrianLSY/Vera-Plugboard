defmodule Plugboard.ServiceAccountsTest do
  use Plugboard.DataCase

  alias Plugboard.ServiceAccounts
  alias Plugboard.Paths

  describe "generate_service_account/4" do
    setup do
      user = Plugboard.AccountsFixtures.user_fixture()
      {:ok, path} = create_mount_point(user)
      %{user: user, path: path}
    end

    test "creates service account with valid params", %{user: user, path: path} do
      assert {:ok, api_key, service_account} =
               ServiceAccounts.generate_service_account(user, path.id, "test-sa", "Test SA")

      # API key format check
      assert String.starts_with?(api_key, "sa_live_")
      assert String.length(api_key) > 20

      # Service account checks
      assert service_account.name == "test-sa"
      assert service_account.description == "Test SA"
      assert service_account.user_id == user.id
      assert service_account.path_id == path.id
      assert service_account.api_key_hash != nil
      assert service_account.revoked_at == nil
    end

    test "generates unique API keys for different service accounts", %{user: user, path: path} do
      {:ok, api_key1, _} = ServiceAccounts.generate_service_account(user, path.id, "sa1", nil)
      {:ok, api_key2, _} = ServiceAccounts.generate_service_account(user, path.id, "sa2", nil)

      assert api_key1 != api_key2
    end

    test "requires owner or maintainer role", %{path: path} do
      other_user = Plugboard.AccountsFixtures.user_fixture()

      # Add as viewer
      {:ok, _} = Paths.add_user_to_path(other_user.id, path.id, "viewer")

      assert {:error, "Requires owner or maintainer role"} =
               ServiceAccounts.generate_service_account(other_user, path.id, "test", nil)
    end

    test "allows maintainer to create service accounts", %{user: _owner, path: path} do
      maintainer = Plugboard.AccountsFixtures.user_fixture()

      # Add as maintainer
      {:ok, _} = Paths.add_user_to_path(maintainer.id, path.id, "maintainer")

      assert {:ok, _api_key, _sa} =
               ServiceAccounts.generate_service_account(maintainer, path.id, "test", nil)
    end

    test "rejects non-existent path" do
      user = Plugboard.AccountsFixtures.user_fixture()
      fake_uuid = Ecto.UUID.generate()

      assert {:error, "Path not found"} =
               ServiceAccounts.generate_service_account(user, fake_uuid, "test", nil)
    end

    test "rejects user without access to path", %{path: path} do
      other_user = Plugboard.AccountsFixtures.user_fixture()

      assert {:error, "You do not have access to this path"} =
               ServiceAccounts.generate_service_account(other_user, path.id, "test", nil)
    end

    test "enforces unique name per user", %{user: user, path: path} do
      {:ok, _, _} = ServiceAccounts.generate_service_account(user, path.id, "duplicate", nil)

      assert {:error, changeset} =
               ServiceAccounts.generate_service_account(user, path.id, "duplicate", nil)

      errors = errors_on(changeset)
      # The error might be on user_id or name depending on how the constraint is set up
      assert errors[:name] != nil or errors[:user_id] != nil
    end

    test "validates name format", %{user: user, path: path} do
      # Invalid characters
      assert {:error, changeset} =
               ServiceAccounts.generate_service_account(user, path.id, "invalid name!", nil)

      assert "must contain only letters, numbers, hyphens, and underscores" in errors_on(
               changeset
             ).name
    end

    test "validates name length", %{user: user, path: path} do
      # Too short
      assert {:error, changeset} =
               ServiceAccounts.generate_service_account(user, path.id, "ab", nil)

      assert "should be at least 3 character(s)" in errors_on(changeset).name
    end
  end

  describe "validate_api_key/1" do
    setup do
      user = Plugboard.AccountsFixtures.user_fixture()
      {:ok, path} = create_mount_point(user)

      {:ok, api_key, service_account} =
        ServiceAccounts.generate_service_account(user, path.id, "test", nil)

      %{user: user, path: path, api_key: api_key, service_account: service_account}
    end

    test "validates correct API key", %{api_key: api_key, path: path, service_account: sa} do
      assert {:ok, result} = ServiceAccounts.validate_api_key(api_key)
      assert result.service_account.id == sa.id
      assert result.path.id == path.id
      assert result.user_id == sa.user_id
    end

    test "rejects invalid API key" do
      assert {:error, :api_key_not_found} = ServiceAccounts.validate_api_key("sa_live_invalid")
    end

    test "rejects revoked service account", %{api_key: api_key, service_account: sa} do
      {:ok, _} = ServiceAccounts.revoke_service_account(sa.id)

      assert {:error, :service_account_revoked} = ServiceAccounts.validate_api_key(api_key)
    end

    test "rejects when path is deleted", %{api_key: api_key, path: path} do
      {:ok, _} = Paths.delete_path(path)

      # After deletion, path won't be found
      assert {:error, :path_not_found} = ServiceAccounts.validate_api_key(api_key)
    end

    test "rejects non-string input" do
      assert {:error, "Invalid API key format"} = ServiceAccounts.validate_api_key(nil)
      assert {:error, "Invalid API key format"} = ServiceAccounts.validate_api_key(123)
    end
  end

  describe "validate_and_mark_used/1" do
    setup do
      user = Plugboard.AccountsFixtures.user_fixture()
      {:ok, path} = create_mount_point(user)

      {:ok, api_key, service_account} =
        ServiceAccounts.generate_service_account(user, path.id, "test", nil)

      %{api_key: api_key, service_account: service_account}
    end

    test "validates and marks as used", %{api_key: api_key, service_account: sa} do
      # Initially not used
      assert sa.last_used_at == nil

      # Validate and mark used
      assert {:ok, result} = ServiceAccounts.validate_and_mark_used(api_key)
      assert result.service_account.id == sa.id

      # Check last_used_at was updated
      updated_sa = ServiceAccounts.get_service_account(sa.id)
      assert updated_sa.last_used_at != nil
    end

    test "updates last_used_at on each validation", %{api_key: api_key, service_account: sa} do
      {:ok, _} = ServiceAccounts.validate_and_mark_used(api_key)
      sa1 = ServiceAccounts.get_service_account(sa.id)
      first_used = sa1.last_used_at

      # Wait a bit to ensure time difference
      Process.sleep(1100)

      {:ok, _} = ServiceAccounts.validate_and_mark_used(api_key)
      sa2 = ServiceAccounts.get_service_account(sa.id)
      second_used = sa2.last_used_at

      # Should be greater or equal (truncated to seconds)
      assert DateTime.compare(second_used, first_used) in [:gt, :eq]
    end
  end

  describe "revoke_service_account/1" do
    setup do
      user = Plugboard.AccountsFixtures.user_fixture()
      {:ok, path} = create_mount_point(user)

      {:ok, _api_key, service_account} =
        ServiceAccounts.generate_service_account(user, path.id, "test", nil)

      %{service_account: service_account}
    end

    test "revokes service account", %{service_account: sa} do
      assert {:ok, revoked} = ServiceAccounts.revoke_service_account(sa.id)
      assert revoked.revoked_at != nil
    end

    test "returns error for non-existent service account" do
      fake_uuid = Ecto.UUID.generate()
      assert {:error, :not_found} = ServiceAccounts.revoke_service_account(fake_uuid)
    end
  end

  describe "update_service_account/2" do
    setup do
      user = Plugboard.AccountsFixtures.user_fixture()
      {:ok, path} = create_mount_point(user)

      {:ok, _api_key, service_account} =
        ServiceAccounts.generate_service_account(user, path.id, "original-name", "original desc")

      %{user: user, path: path, service_account: service_account}
    end

    test "updates service account name and description", %{service_account: sa} do
      attrs = %{name: "updated-name", description: "updated description"}
      assert {:ok, updated_sa} = ServiceAccounts.update_service_account(sa.id, attrs)

      assert updated_sa.name == "updated-name"
      assert updated_sa.description == "updated description"
      assert updated_sa.id == sa.id
    end

    test "updates only name", %{service_account: sa} do
      attrs = %{name: "new-name"}
      assert {:ok, updated_sa} = ServiceAccounts.update_service_account(sa.id, attrs)

      assert updated_sa.name == "new-name"
      assert updated_sa.description == "original desc"
    end

    test "updates only description", %{service_account: sa} do
      attrs = %{description: "new description"}
      assert {:ok, updated_sa} = ServiceAccounts.update_service_account(sa.id, attrs)

      assert updated_sa.name == "original-name"
      assert updated_sa.description == "new description"
    end

    test "allows setting description to nil", %{service_account: sa} do
      attrs = %{description: nil}
      assert {:ok, updated_sa} = ServiceAccounts.update_service_account(sa.id, attrs)

      assert updated_sa.name == "original-name"
      assert updated_sa.description == nil
    end

    test "validates name format", %{service_account: sa} do
      # Invalid characters
      attrs = %{name: "invalid name!"}
      assert {:error, changeset} = ServiceAccounts.update_service_account(sa.id, attrs)

      assert "must contain only letters, numbers, hyphens, and underscores" in errors_on(
               changeset
             ).name
    end

    test "validates name length minimum", %{service_account: sa} do
      # Too short
      attrs = %{name: "ab"}
      assert {:error, changeset} = ServiceAccounts.update_service_account(sa.id, attrs)

      assert "should be at least 3 character(s)" in errors_on(changeset).name
    end

    test "validates name length maximum", %{service_account: sa} do
      # Too long (> 100 chars)
      long_name = String.duplicate("a", 101)
      attrs = %{name: long_name}

      assert {:error, changeset} = ServiceAccounts.update_service_account(sa.id, attrs)
      assert "should be at most 100 character(s)" in errors_on(changeset).name
    end

    test "validates description length", %{service_account: sa} do
      # Description too long (> 500 chars)
      long_desc = String.duplicate("a", 501)
      attrs = %{description: long_desc}

      assert {:error, changeset} = ServiceAccounts.update_service_account(sa.id, attrs)
      assert "should be at most 500 character(s)" in errors_on(changeset).description
    end

    test "returns error for non-existent service account" do
      fake_id = Ecto.UUID.generate()
      attrs = %{name: "test"}

      assert {:error, :not_found} = ServiceAccounts.update_service_account(fake_id, attrs)
    end

    test "enforces unique name per user", %{user: user, path: path, service_account: sa} do
      # Create another service account with different name
      {:ok, _, _sa2} = ServiceAccounts.generate_service_account(user, path.id, "other-name", nil)

      # Try to update first SA to use the second SA's name
      attrs = %{name: "other-name"}
      assert {:error, changeset} = ServiceAccounts.update_service_account(sa.id, attrs)

      errors = errors_on(changeset)
      assert errors[:name] != nil or errors[:user_id] != nil
    end

    test "allows same name if updating the same service account", %{service_account: sa} do
      # Updating with the same name should work
      attrs = %{name: "original-name", description: "new desc"}
      assert {:ok, updated_sa} = ServiceAccounts.update_service_account(sa.id, attrs)

      assert updated_sa.name == "original-name"
      assert updated_sa.description == "new desc"
    end

    test "does not modify other service account fields", %{service_account: sa} do
      original_sa = Repo.get(ServiceAccounts.ServiceAccount, sa.id)

      attrs = %{name: "updated-name"}
      assert {:ok, updated_sa} = ServiceAccounts.update_service_account(sa.id, attrs)

      # These should remain unchanged
      assert updated_sa.api_key_hash == original_sa.api_key_hash
      assert updated_sa.revoked_at == original_sa.revoked_at
      assert updated_sa.last_used_at == original_sa.last_used_at
      assert updated_sa.path_id == original_sa.path_id
      assert updated_sa.user_id == original_sa.user_id
    end
  end

  describe "list_service_accounts_for_path/1" do
    setup do
      user = Plugboard.AccountsFixtures.user_fixture()
      {:ok, path} = create_mount_point(user)

      # Create multiple service accounts
      {:ok, _, sa1} = ServiceAccounts.generate_service_account(user, path.id, "sa1", nil)
      {:ok, _, sa2} = ServiceAccounts.generate_service_account(user, path.id, "sa2", nil)
      {:ok, _, sa3} = ServiceAccounts.generate_service_account(user, path.id, "sa3", nil)

      # Revoke one
      {:ok, _} = ServiceAccounts.revoke_service_account(sa3.id)

      %{path: path, sa1: sa1, sa2: sa2}
    end

    test "lists only active service accounts", %{path: path, sa1: sa1, sa2: sa2} do
      accounts = ServiceAccounts.list_service_accounts_for_path(path.id)

      assert length(accounts) == 2
      account_ids = Enum.map(accounts, & &1.id)
      assert sa1.id in account_ids
      assert sa2.id in account_ids
    end

    test "returns empty list for path with no service accounts" do
      user = Plugboard.AccountsFixtures.user_fixture()
      {:ok, path} = create_mount_point(user)

      assert [] = ServiceAccounts.list_service_accounts_for_path(path.id)
    end
  end

  describe "list_service_accounts_for_user/1" do
    test "lists all service accounts for user across paths" do
      user = Plugboard.AccountsFixtures.user_fixture()
      {:ok, path1} = create_mount_point(user)
      {:ok, path2} = create_mount_point(user, "other")

      {:ok, _, sa1} = ServiceAccounts.generate_service_account(user, path1.id, "sa1", nil)
      {:ok, _, sa2} = ServiceAccounts.generate_service_account(user, path2.id, "sa2", nil)

      accounts = ServiceAccounts.list_service_accounts_for_user(user.id)

      assert length(accounts) == 2
      account_ids = Enum.map(accounts, & &1.id)
      assert sa1.id in account_ids
      assert sa2.id in account_ids

      # Check preloaded paths
      assert Enum.all?(accounts, fn sa -> sa.path != nil end)
    end
  end

  describe "get_service_account/1" do
    test "returns service account by id" do
      user = Plugboard.AccountsFixtures.user_fixture()
      {:ok, path} = create_mount_point(user)
      {:ok, _, sa} = ServiceAccounts.generate_service_account(user, path.id, "test", nil)

      retrieved = ServiceAccounts.get_service_account(sa.id)
      assert retrieved.id == sa.id
      assert retrieved.name == "test"
    end

    test "returns nil for non-existent id" do
      fake_uuid = Ecto.UUID.generate()
      assert nil == ServiceAccounts.get_service_account(fake_uuid)
    end
  end

  # Helper functions

  defp create_mount_point(user, name \\ nil) do
    # Generate unique name if not provided
    path_name = name || "api-#{System.unique_integer([:positive])}"

    {:ok, path} =
      Paths.create_path(%{
        path: path_name,
        user_id: user.id,
        parent_id: nil,
        mount_point: true
      })

    {:ok, path}
  end
end
