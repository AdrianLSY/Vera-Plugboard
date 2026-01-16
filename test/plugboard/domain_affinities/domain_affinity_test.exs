defmodule Plugboard.DomainAffinities.DomainAffinityTest do
  use Plugboard.DataCase

  import Plugboard.AccountsFixtures

  alias Plugboard.DomainAffinities.DomainAffinity
  alias Plugboard.Paths

  describe "changeset/2" do
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

    test "valid changeset with exact domain", %{path: path} do
      attrs = %{domain: "api.example.com", path_id: path.id}
      changeset = DomainAffinity.changeset(%DomainAffinity{}, attrs)

      assert changeset.valid?
      assert get_change(changeset, :domain) == "api.example.com"
    end

    test "valid changeset with wildcard domain", %{path: path} do
      attrs = %{domain: "*.api.example.com", path_id: path.id}
      changeset = DomainAffinity.changeset(%DomainAffinity{}, attrs)

      assert changeset.valid?
      assert get_change(changeset, :domain) == "*.api.example.com"
    end

    test "normalizes domain to lowercase", %{path: path} do
      attrs = %{domain: "API.Example.COM", path_id: path.id}
      changeset = DomainAffinity.changeset(%DomainAffinity{}, attrs)

      assert changeset.valid?
      assert get_change(changeset, :domain) == "api.example.com"
    end

    test "strips port from domain", %{path: path} do
      attrs = %{domain: "api.example.com:8080", path_id: path.id}
      changeset = DomainAffinity.changeset(%DomainAffinity{}, attrs)

      assert changeset.valid?
      assert get_change(changeset, :domain) == "api.example.com"
    end

    test "trims whitespace from domain", %{path: path} do
      attrs = %{domain: "  api.example.com  ", path_id: path.id}
      changeset = DomainAffinity.changeset(%DomainAffinity{}, attrs)

      assert changeset.valid?
      assert get_change(changeset, :domain) == "api.example.com"
    end

    test "invalid changeset without domain", %{path: path} do
      attrs = %{path_id: path.id}
      changeset = DomainAffinity.changeset(%DomainAffinity{}, attrs)

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).domain
    end

    test "invalid changeset without path_id" do
      attrs = %{domain: "api.example.com"}
      changeset = DomainAffinity.changeset(%DomainAffinity{}, attrs)

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).path_id
    end

    test "invalid domain format - no dots", %{path: path} do
      attrs = %{domain: "localhost", path_id: path.id}
      changeset = DomainAffinity.changeset(%DomainAffinity{}, attrs)

      refute changeset.valid?
      assert "invalid domain format" in errors_on(changeset).domain
    end

    test "invalid domain format - starts with dot", %{path: path} do
      attrs = %{domain: ".example.com", path_id: path.id}
      changeset = DomainAffinity.changeset(%DomainAffinity{}, attrs)

      refute changeset.valid?
      assert "invalid domain format" in errors_on(changeset).domain
    end

    test "invalid domain format - ends with dot", %{path: path} do
      attrs = %{domain: "example.com.", path_id: path.id}
      changeset = DomainAffinity.changeset(%DomainAffinity{}, attrs)

      refute changeset.valid?
      assert "invalid domain format" in errors_on(changeset).domain
    end

    test "invalid wildcard format - wildcard in middle", %{path: path} do
      attrs = %{domain: "api.*.example.com", path_id: path.id}
      changeset = DomainAffinity.changeset(%DomainAffinity{}, attrs)

      refute changeset.valid?
      assert "invalid domain format" in errors_on(changeset).domain
    end

    test "invalid wildcard format - wildcard at end", %{path: path} do
      attrs = %{domain: "api.example.com.*", path_id: path.id}
      changeset = DomainAffinity.changeset(%DomainAffinity{}, attrs)

      refute changeset.valid?
      assert "invalid domain format" in errors_on(changeset).domain
    end

    test "invalid wildcard format - missing dot after asterisk", %{path: path} do
      attrs = %{domain: "*example.com", path_id: path.id}
      changeset = DomainAffinity.changeset(%DomainAffinity{}, attrs)

      refute changeset.valid?
      # "*example.com" doesn't start with "*." so it's treated as invalid domain format
      assert "invalid domain format" in errors_on(changeset).domain
    end

    test "rejects path that is not a mount point", %{user: user} do
      {:ok, non_mount_path} =
        Paths.create_path(%{
          path: "notmount",
          parent_id: nil,
          mount_point: false,
          user_id: user.id
        })

      attrs = %{domain: "api.example.com", path_id: non_mount_path.id}
      changeset = DomainAffinity.changeset(%DomainAffinity{}, attrs)

      refute changeset.valid?
      assert "path must be a mount point" in errors_on(changeset).path_id
    end

    test "rejects deleted path", %{path: path} do
      # Soft delete the path
      Paths.delete_path(path)

      attrs = %{domain: "api.example.com", path_id: path.id}
      changeset = DomainAffinity.changeset(%DomainAffinity{}, attrs)

      refute changeset.valid?
      assert "path is deleted" in errors_on(changeset).path_id
    end

    test "rejects non-existent path" do
      fake_uuid = Ecto.UUID.generate()
      attrs = %{domain: "api.example.com", path_id: fake_uuid}
      changeset = DomainAffinity.changeset(%DomainAffinity{}, attrs)

      refute changeset.valid?
      assert "path not found" in errors_on(changeset).path_id
    end
  end

  describe "is_wildcard?/1" do
    test "returns true for wildcard domain" do
      domain_affinity = %DomainAffinity{domain: "*.example.com"}
      assert DomainAffinity.is_wildcard?(domain_affinity)
    end

    test "returns false for exact domain" do
      domain_affinity = %DomainAffinity{domain: "api.example.com"}
      refute DomainAffinity.is_wildcard?(domain_affinity)
    end
  end
end
