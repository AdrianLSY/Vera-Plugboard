defmodule Plugboard.DomainAffinitiesTest do
  use Plugboard.DataCase

  import Plugboard.AccountsFixtures

  alias Plugboard.DomainAffinities
  alias Plugboard.Paths

  setup do
    user = user_fixture()

    # Create a mount point for testing
    {:ok, path} =
      Paths.create_path(%{
        path: "api",
        parent_id: nil,
        mount_point: true,
        user_id: user.id
      })

    %{path: path, user: user}
  end

  describe "list_domain_affinities/0" do
    test "returns all active domain affinities", %{path: path} do
      {:ok, da1} =
        DomainAffinities.create_domain_affinity(%{
          domain: "api.example.com",
          path_id: path.id
        })

      {:ok, da2} =
        DomainAffinities.create_domain_affinity(%{
          domain: "*.api.example.com",
          path_id: path.id
        })

      result = DomainAffinities.list_domain_affinities()

      assert length(result) == 2
      assert Enum.any?(result, &(&1.id == da1.id))
      assert Enum.any?(result, &(&1.id == da2.id))
    end

    test "does not return soft-deleted domain affinities", %{path: path} do
      {:ok, da} =
        DomainAffinities.create_domain_affinity(%{
          domain: "api.example.com",
          path_id: path.id
        })

      {:ok, _deleted} = DomainAffinities.delete_domain_affinity(da.id)

      result = DomainAffinities.list_domain_affinities()

      assert result == []
    end

    test "returns empty list when no domain affinities exist" do
      result = DomainAffinities.list_domain_affinities()
      assert result == []
    end
  end

  describe "list_domain_affinities_for_path/1" do
    test "returns domain affinities for specific path", %{path: path, user: user} do
      {:ok, other_path} =
        Paths.create_path(%{
          path: "users",
          parent_id: nil,
          mount_point: true,
          user_id: user.id
        })

      {:ok, da1} =
        DomainAffinities.create_domain_affinity(%{
          domain: "api.example.com",
          path_id: path.id
        })

      {:ok, _da2} =
        DomainAffinities.create_domain_affinity(%{
          domain: "users.example.com",
          path_id: other_path.id
        })

      result = DomainAffinities.list_domain_affinities_for_path(path.id)

      assert length(result) == 1
      assert hd(result).id == da1.id
    end

    test "returns empty list for path with no domain affinities", %{path: path} do
      result = DomainAffinities.list_domain_affinities_for_path(path.id)
      assert result == []
    end
  end

  describe "get_domain_affinity/1" do
    test "returns domain affinity by id", %{path: path} do
      {:ok, da} =
        DomainAffinities.create_domain_affinity(%{
          domain: "api.example.com",
          path_id: path.id
        })

      result = DomainAffinities.get_domain_affinity(da.id)

      assert result.id == da.id
      assert result.domain == "api.example.com"
    end

    test "returns nil for non-existent id" do
      fake_id = Ecto.UUID.generate()
      assert DomainAffinities.get_domain_affinity(fake_id) == nil
    end

    test "returns nil for soft-deleted domain affinity", %{path: path} do
      {:ok, da} =
        DomainAffinities.create_domain_affinity(%{
          domain: "api.example.com",
          path_id: path.id
        })

      {:ok, _deleted} = DomainAffinities.delete_domain_affinity(da.id)

      assert DomainAffinities.get_domain_affinity(da.id) == nil
    end
  end

  describe "get_by_domain/1" do
    test "returns domain affinity by domain string", %{path: path} do
      {:ok, da} =
        DomainAffinities.create_domain_affinity(%{
          domain: "api.example.com",
          path_id: path.id
        })

      result = DomainAffinities.get_by_domain("api.example.com")

      assert result.id == da.id
      assert result.domain == "api.example.com"
    end

    test "normalizes domain before lookup", %{path: path} do
      {:ok, da} =
        DomainAffinities.create_domain_affinity(%{
          domain: "api.example.com",
          path_id: path.id
        })

      # Lookup with uppercase
      result = DomainAffinities.get_by_domain("API.EXAMPLE.COM")

      assert result.id == da.id
    end

    test "strips port before lookup", %{path: path} do
      {:ok, da} =
        DomainAffinities.create_domain_affinity(%{
          domain: "api.example.com",
          path_id: path.id
        })

      # Lookup with port
      result = DomainAffinities.get_by_domain("api.example.com:8080")

      assert result.id == da.id
    end

    test "returns nil for non-existent domain" do
      assert DomainAffinities.get_by_domain("nonexistent.com") == nil
    end
  end

  describe "create_domain_affinity/1" do
    test "creates domain affinity with valid attributes", %{path: path} do
      attrs = %{domain: "api.example.com", path_id: path.id}

      {:ok, da} = DomainAffinities.create_domain_affinity(attrs)

      assert da.domain == "api.example.com"
      assert da.path_id == path.id
      assert da.deleted_at == nil
    end

    test "creates wildcard domain affinity", %{path: path} do
      attrs = %{domain: "*.api.example.com", path_id: path.id}

      {:ok, da} = DomainAffinities.create_domain_affinity(attrs)

      assert da.domain == "*.api.example.com"
    end

    test "returns error for invalid domain format", %{path: path} do
      attrs = %{domain: "invalid", path_id: path.id}

      {:error, changeset} = DomainAffinities.create_domain_affinity(attrs)

      refute changeset.valid?
      assert "invalid domain format" in errors_on(changeset).domain
    end

    test "returns error for duplicate domain", %{path: path} do
      attrs = %{domain: "api.example.com", path_id: path.id}

      {:ok, _da1} = DomainAffinities.create_domain_affinity(attrs)
      {:error, changeset} = DomainAffinities.create_domain_affinity(attrs)

      refute changeset.valid?
      assert "has already been taken" in errors_on(changeset).domain
    end

    test "returns error when path is not a mount point", %{user: user} do
      {:ok, non_mount} =
        Paths.create_path(%{
          path: "notmount",
          parent_id: nil,
          mount_point: false,
          user_id: user.id
        })

      attrs = %{domain: "api.example.com", path_id: non_mount.id}

      {:error, changeset} = DomainAffinities.create_domain_affinity(attrs)

      refute changeset.valid?
    end
  end

  describe "update_domain_affinity/2" do
    test "updates domain affinity", %{path: path} do
      {:ok, da} =
        DomainAffinities.create_domain_affinity(%{
          domain: "api.example.com",
          path_id: path.id
        })

      {:ok, updated} =
        DomainAffinities.update_domain_affinity(da.id, %{domain: "newapi.example.com"})

      assert updated.domain == "newapi.example.com"
      assert updated.id == da.id
    end

    test "returns error for invalid domain", %{path: path} do
      {:ok, da} =
        DomainAffinities.create_domain_affinity(%{
          domain: "api.example.com",
          path_id: path.id
        })

      {:error, changeset} =
        DomainAffinities.update_domain_affinity(da.id, %{domain: "invalid"})

      refute changeset.valid?
    end

    test "returns error for non-existent id" do
      fake_id = Ecto.UUID.generate()

      {:error, :not_found} =
        DomainAffinities.update_domain_affinity(fake_id, %{domain: "api.example.com"})
    end
  end

  describe "delete_domain_affinity/1" do
    test "soft-deletes domain affinity", %{path: path} do
      {:ok, da} =
        DomainAffinities.create_domain_affinity(%{
          domain: "api.example.com",
          path_id: path.id
        })

      {:ok, deleted} = DomainAffinities.delete_domain_affinity(da.id)

      assert deleted.id == da.id
      assert deleted.deleted_at != nil

      # Verify it's not returned in queries
      assert DomainAffinities.get_domain_affinity(da.id) == nil
    end

    test "returns error for non-existent id" do
      fake_id = Ecto.UUID.generate()

      {:error, :not_found} = DomainAffinities.delete_domain_affinity(fake_id)
    end

    test "returns error when already deleted", %{path: path} do
      {:ok, da} =
        DomainAffinities.create_domain_affinity(%{
          domain: "api.example.com",
          path_id: path.id
        })

      {:ok, _deleted} = DomainAffinities.delete_domain_affinity(da.id)
      {:error, :not_found} = DomainAffinities.delete_domain_affinity(da.id)
    end
  end

  describe "normalize_domain/1" do
    test "converts to lowercase" do
      assert DomainAffinities.normalize_domain("API.EXAMPLE.COM") == "api.example.com"
    end

    test "trims whitespace" do
      assert DomainAffinities.normalize_domain("  api.example.com  ") == "api.example.com"
    end

    test "strips port" do
      assert DomainAffinities.normalize_domain("api.example.com:8080") == "api.example.com"
    end

    test "handles all normalizations together" do
      assert DomainAffinities.normalize_domain("  API.EXAMPLE.COM:8080  ") == "api.example.com"
    end
  end
end
