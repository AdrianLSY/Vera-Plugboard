defmodule Plugboard.Hooks.HookTest do
  use Plugboard.DataCase

  alias Plugboard.Hooks.Hook
  alias Plugboard.Paths

  import Plugboard.AccountsFixtures

  # Helper to create a path for testing
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

  defp create_mount_point(user, attrs \\ %{}) do
    path = create_path(user, attrs)
    {:ok, mount} = Paths.update_path(path, %{mount_point: true})
    mount
  end

  describe "create_changeset/2" do
    setup do
      user = user_fixture()
      path = create_path(user)
      target_path = create_mount_point(user)
      %{user: user, path: path, target_path: target_path}
    end

    test "valid with mount_point target type", %{path: path, target_path: target_path} do
      attrs = %{
        path_id: path.id,
        name: "Auth Hook",
        description: "Validates authentication",
        target_type: "mount_point",
        target_path_id: target_path.id,
        execution_order: 0,
        timeout_ms: 5000
      }

      changeset = Hook.create_changeset(%Hook{}, attrs)
      assert changeset.valid?
    end

    test "valid with http_url target type", %{path: path} do
      attrs = %{
        path_id: path.id,
        name: "External Hook",
        description: "Calls external service",
        target_type: "http_url",
        target_url: "https://example.com/webhook",
        execution_order: 0,
        timeout_ms: 5000
      }

      changeset = Hook.create_changeset(%Hook{}, attrs)
      assert changeset.valid?
    end

    test "requires path_id", %{target_path: target_path} do
      attrs = %{
        name: "Test Hook",
        target_type: "mount_point",
        target_path_id: target_path.id,
        execution_order: 0,
        timeout_ms: 5000
      }

      changeset = Hook.create_changeset(%Hook{}, attrs)
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).path_id
    end

    test "requires name", %{path: path, target_path: target_path} do
      attrs = %{
        path_id: path.id,
        target_type: "mount_point",
        target_path_id: target_path.id,
        execution_order: 0,
        timeout_ms: 5000
      }

      changeset = Hook.create_changeset(%Hook{}, attrs)
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).name
    end

    test "requires target_type (explicit nil)", %{path: path} do
      attrs = %{
        path_id: path.id,
        name: "Test Hook",
        target_type: nil,
        execution_order: 0,
        timeout_ms: 5000
      }

      changeset = Hook.create_changeset(%Hook{}, attrs)
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).target_type
    end

    test "validates target_type inclusion", %{path: path} do
      attrs = %{
        path_id: path.id,
        name: "Test Hook",
        target_type: "invalid_type",
        execution_order: 0,
        timeout_ms: 5000
      }

      changeset = Hook.create_changeset(%Hook{}, attrs)
      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).target_type
    end

    test "requires target_path_id when target_type is mount_point", %{path: path} do
      attrs = %{
        path_id: path.id,
        name: "Test Hook",
        target_type: "mount_point",
        execution_order: 0,
        timeout_ms: 5000
      }

      changeset = Hook.create_changeset(%Hook{}, attrs)
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).target_path_id
    end

    test "requires target_url when target_type is http_url", %{path: path} do
      attrs = %{
        path_id: path.id,
        name: "Test Hook",
        target_type: "http_url",
        execution_order: 0,
        timeout_ms: 5000
      }

      changeset = Hook.create_changeset(%Hook{}, attrs)
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).target_url
    end

    test "rejects target_url when target_type is mount_point", %{
      path: path,
      target_path: target_path
    } do
      attrs = %{
        path_id: path.id,
        name: "Test Hook",
        target_type: "mount_point",
        target_path_id: target_path.id,
        target_url: "https://example.com/webhook",
        execution_order: 0,
        timeout_ms: 5000
      }

      changeset = Hook.create_changeset(%Hook{}, attrs)
      refute changeset.valid?
      assert "must be nil when target_type is mount_point" in errors_on(changeset).target_url
    end

    test "rejects target_path_id when target_type is http_url", %{
      path: path,
      target_path: target_path
    } do
      attrs = %{
        path_id: path.id,
        name: "Test Hook",
        target_type: "http_url",
        target_url: "https://example.com/webhook",
        target_path_id: target_path.id,
        execution_order: 0,
        timeout_ms: 5000
      }

      changeset = Hook.create_changeset(%Hook{}, attrs)
      refute changeset.valid?
      assert "must be nil when target_type is http_url" in errors_on(changeset).target_path_id
    end

    test "validates target_url is valid HTTP URL", %{path: path} do
      attrs = %{
        path_id: path.id,
        name: "Test Hook",
        target_type: "http_url",
        target_url: "not-a-url",
        execution_order: 0,
        timeout_ms: 5000
      }

      changeset = Hook.create_changeset(%Hook{}, attrs)
      refute changeset.valid?
      assert "must be a valid HTTP or HTTPS URL" in errors_on(changeset).target_url
    end

    test "validates target_url accepts https", %{path: path} do
      attrs = %{
        path_id: path.id,
        name: "Test Hook",
        target_type: "http_url",
        target_url: "https://secure.example.com/webhook",
        execution_order: 0,
        timeout_ms: 5000
      }

      changeset = Hook.create_changeset(%Hook{}, attrs)
      assert changeset.valid?
    end

    test "validates target_url accepts http", %{path: path} do
      attrs = %{
        path_id: path.id,
        name: "Test Hook",
        target_type: "http_url",
        target_url: "http://internal.example.com/webhook",
        execution_order: 0,
        timeout_ms: 5000
      }

      changeset = Hook.create_changeset(%Hook{}, attrs)
      assert changeset.valid?
    end

    test "validates timeout_ms minimum value", %{path: path} do
      attrs = %{
        path_id: path.id,
        name: "Test Hook",
        target_type: "http_url",
        target_url: "https://example.com/webhook",
        execution_order: 0,
        timeout_ms: 0
      }

      changeset = Hook.create_changeset(%Hook{}, attrs)
      refute changeset.valid?
      assert "must be greater than 0" in errors_on(changeset).timeout_ms
    end

    test "validates timeout_ms maximum value", %{path: path} do
      attrs = %{
        path_id: path.id,
        name: "Test Hook",
        target_type: "http_url",
        target_url: "https://example.com/webhook",
        execution_order: 0,
        timeout_ms: 60_001
      }

      changeset = Hook.create_changeset(%Hook{}, attrs)
      refute changeset.valid?
      assert "must be less than or equal to 60000" in errors_on(changeset).timeout_ms
    end

    test "validates execution_order is non-negative", %{path: path} do
      attrs = %{
        path_id: path.id,
        name: "Test Hook",
        target_type: "http_url",
        target_url: "https://example.com/webhook",
        execution_order: -1,
        timeout_ms: 5000
      }

      changeset = Hook.create_changeset(%Hook{}, attrs)
      refute changeset.valid?
      assert "must be greater than or equal to 0" in errors_on(changeset).execution_order
    end

    test "validates allowed_status_codes contains valid HTTP codes", %{path: path} do
      attrs = %{
        path_id: path.id,
        name: "Test Hook",
        target_type: "http_url",
        target_url: "https://example.com/webhook",
        execution_order: 0,
        timeout_ms: 5000,
        allowed_status_codes: [99, 600]
      }

      changeset = Hook.create_changeset(%Hook{}, attrs)
      refute changeset.valid?

      assert "must be a list of valid HTTP status codes (100-599)" in errors_on(changeset).allowed_status_codes
    end

    test "validates allowed_status_codes is non-empty", %{path: path} do
      attrs = %{
        path_id: path.id,
        name: "Test Hook",
        target_type: "http_url",
        target_url: "https://example.com/webhook",
        execution_order: 0,
        timeout_ms: 5000,
        allowed_status_codes: []
      }

      changeset = Hook.create_changeset(%Hook{}, attrs)
      refute changeset.valid?
      assert "must contain at least one status code" in errors_on(changeset).allowed_status_codes
    end

    test "accepts valid allowed_status_codes", %{path: path} do
      attrs = %{
        path_id: path.id,
        name: "Test Hook",
        target_type: "http_url",
        target_url: "https://example.com/webhook",
        execution_order: 0,
        timeout_ms: 5000,
        allowed_status_codes: [200, 201, 202, 204, 301, 400, 500]
      }

      changeset = Hook.create_changeset(%Hook{}, attrs)
      assert changeset.valid?
    end

    test "validates forward_headers is list of strings", %{path: path} do
      attrs = %{
        path_id: path.id,
        name: "Test Hook",
        target_type: "http_url",
        target_url: "https://example.com/webhook",
        execution_order: 0,
        timeout_ms: 5000,
        forward_headers: [123, "authorization"]
      }

      changeset = Hook.create_changeset(%Hook{}, attrs)
      refute changeset.valid?
      # Ecto's array type validation returns "is invalid" for non-string elements
      assert "is invalid" in errors_on(changeset).forward_headers
    end

    test "accepts valid forward_headers", %{path: path} do
      attrs = %{
        path_id: path.id,
        name: "Test Hook",
        target_type: "http_url",
        target_url: "https://example.com/webhook",
        execution_order: 0,
        timeout_ms: 5000,
        forward_headers: ["authorization", "x-request-id", "content-type"]
      }

      changeset = Hook.create_changeset(%Hook{}, attrs)
      assert changeset.valid?
    end

    test "uses default values for optional fields", %{path: path} do
      attrs = %{
        path_id: path.id,
        name: "Test Hook",
        target_type: "http_url",
        target_url: "https://example.com/webhook",
        execution_order: 0,
        timeout_ms: 5000
      }

      changeset = Hook.create_changeset(%Hook{}, attrs)
      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :allowed_status_codes) == [200, 201, 202, 204]
      assert Ecto.Changeset.get_field(changeset, :forward_headers) == []
      assert Ecto.Changeset.get_field(changeset, :forward_query_params) == false
    end
  end

  describe "update_changeset/2" do
    setup do
      user = user_fixture()
      path = create_path(user)
      target_path = create_mount_point(user)

      hook = %Hook{
        id: Ecto.UUID.generate(),
        path_id: path.id,
        name: "Original Hook",
        target_type: "http_url",
        target_url: "https://example.com/webhook",
        execution_order: 0,
        timeout_ms: 5000,
        allowed_status_codes: [200],
        forward_headers: [],
        forward_query_params: false
      }

      %{hook: hook, target_path: target_path}
    end

    test "updates name", %{hook: hook} do
      changeset = Hook.update_changeset(hook, %{name: "Updated Hook"})
      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :name) == "Updated Hook"
    end

    test "updates timeout_ms", %{hook: hook} do
      changeset = Hook.update_changeset(hook, %{timeout_ms: 10_000})
      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :timeout_ms) == 10_000
    end

    test "updates target_type from http_url to mount_point", %{
      hook: hook,
      target_path: target_path
    } do
      changeset =
        Hook.update_changeset(hook, %{
          target_type: "mount_point",
          target_path_id: target_path.id,
          target_url: nil
        })

      assert changeset.valid?
    end

    test "validates updated fields", %{hook: hook} do
      changeset = Hook.update_changeset(hook, %{timeout_ms: -1})
      refute changeset.valid?
      assert "must be greater than 0" in errors_on(changeset).timeout_ms
    end
  end

  describe "delete_changeset/1" do
    test "sets deleted_at to current time" do
      hook = %Hook{
        id: Ecto.UUID.generate(),
        path_id: Ecto.UUID.generate(),
        name: "Test Hook",
        target_type: "http_url",
        target_url: "https://example.com/webhook",
        execution_order: 0,
        timeout_ms: 5000,
        deleted_at: nil
      }

      changeset = Hook.delete_changeset(hook)
      assert changeset.valid?

      deleted_at = Ecto.Changeset.get_field(changeset, :deleted_at)
      assert deleted_at != nil
      assert DateTime.diff(DateTime.utc_now(), deleted_at, :second) < 2
    end
  end
end
