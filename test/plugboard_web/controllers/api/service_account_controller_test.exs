defmodule PlugboardWeb.Api.ServiceAccountControllerTest do
  use PlugboardWeb.ConnCase

  alias Plugboard.ServiceAccounts
  alias Plugboard.Paths

  setup %{conn: conn} do
    user = Plugboard.AccountsFixtures.user_fixture()
    {:ok, path} = create_mount_point(user)

    conn = log_in_user(conn, user)

    %{conn: conn, user: user, path: path}
  end

  describe "POST /api/paths/:path_id/service-accounts" do
    test "creates service account with valid params", %{conn: conn, path: path} do
      conn =
        post(conn, ~p"/api/paths/#{path.id}/service-accounts", %{
          "name" => "production-cluster",
          "description" => "Production auto-scaling"
        })

      assert %{
               "api_key" => api_key,
               "id" => id,
               "name" => "production-cluster",
               "description" => "Production auto-scaling",
               "path_id" => path_id,
               "created_at" => _,
               "message" => message
             } = json_response(conn, 201)

      assert String.starts_with?(api_key, "pb_sa_")
      assert is_binary(id)
      assert path_id == path.id
      assert message =~ "Store this API key securely"
    end

    test "creates service account without description", %{conn: conn, path: path} do
      conn =
        post(conn, ~p"/api/paths/#{path.id}/service-accounts", %{
          "name" => "test-cluster"
        })

      assert %{"name" => "test-cluster", "description" => nil} = json_response(conn, 201)
    end

    test "requires name parameter", %{conn: conn, path: path} do
      conn = post(conn, ~p"/api/paths/#{path.id}/service-accounts", %{})

      assert %{"error" => "Name is required"} = json_response(conn, 400)
    end

    test "rejects empty name", %{conn: conn, path: path} do
      conn =
        post(conn, ~p"/api/paths/#{path.id}/service-accounts", %{
          "name" => "   "
        })

      assert %{"error" => "Name is required"} = json_response(conn, 400)
    end

    test "validates name format", %{conn: conn, path: path} do
      conn =
        post(conn, ~p"/api/paths/#{path.id}/service-accounts", %{
          "name" => "invalid name!"
        })

      assert %{"error" => "Failed to create service account", "details" => details} =
               json_response(conn, 422)

      assert details["name"] != nil
    end

    test "requires owner or maintainer role", %{conn: _conn, user: user, path: path} do
      viewer = Plugboard.AccountsFixtures.user_fixture()
      {:ok, _} = Paths.add_user_to_path(user.id, viewer.id, path.id, "viewer")

      conn = build_conn() |> log_in_user(viewer)

      conn =
        post(conn, ~p"/api/paths/#{path.id}/service-accounts", %{
          "name" => "test"
        })

      assert %{"error" => error} = json_response(conn, 403)
      assert error =~ "Requires owner or maintainer role"
    end

    test "allows maintainer to create", %{user: user, path: path} do
      maintainer = Plugboard.AccountsFixtures.user_fixture()
      {:ok, _} = Paths.add_user_to_path(user.id, maintainer.id, path.id, "maintainer")

      conn = build_conn() |> log_in_user(maintainer)

      conn =
        post(conn, ~p"/api/paths/#{path.id}/service-accounts", %{
          "name" => "test"
        })

      assert json_response(conn, 201)
    end
  end

  describe "GET /api/paths/:path_id/service-accounts" do
    setup %{user: user, path: path} do
      {:ok, _, sa1} = ServiceAccounts.generate_service_account(user, path.id, "sa1", "First")
      {:ok, _, sa2} = ServiceAccounts.generate_service_account(user, path.id, "sa2", "Second")
      {:ok, _, sa3} = ServiceAccounts.generate_service_account(user, path.id, "sa3", nil)

      # Revoke one
      {:ok, _} = ServiceAccounts.revoke_service_account(user.id, sa3.id)

      %{sa1: sa1, sa2: sa2}
    end

    test "lists service accounts for path", %{conn: conn, path: path, sa1: sa1, sa2: sa2} do
      conn = get(conn, ~p"/api/paths/#{path.id}/service-accounts")

      assert %{"service_accounts" => accounts} = json_response(conn, 200)
      assert length(accounts) == 2

      ids = Enum.map(accounts, & &1["id"])
      assert sa1.id in ids
      assert sa2.id in ids

      # Verify structure and no API key hash
      account = List.first(accounts)
      assert Map.has_key?(account, "id")
      assert Map.has_key?(account, "name")
      assert Map.has_key?(account, "description")
      assert Map.has_key?(account, "last_used_at")
      assert Map.has_key?(account, "created_at")
      refute Map.has_key?(account, "api_key_hash")
    end

    test "returns empty list when no service accounts", %{conn: conn, user: user} do
      {:ok, path2} = create_mount_point(user, "other")

      conn = get(conn, ~p"/api/paths/#{path2.id}/service-accounts")

      assert %{"service_accounts" => []} = json_response(conn, 200)
    end

    test "requires path access", %{conn: _conn} do
      other_user = Plugboard.AccountsFixtures.user_fixture()
      {:ok, other_path} = create_mount_point(other_user, "private")

      viewer = Plugboard.AccountsFixtures.user_fixture()
      conn = build_conn() |> log_in_user(viewer)

      conn = get(conn, ~p"/api/paths/#{other_path.id}/service-accounts")

      assert %{"error" => "You do not have access to this path"} = json_response(conn, 403)
    end
  end

  describe "GET /api/service-accounts" do
    test "lists all user's service accounts", %{conn: conn, user: user} do
      {:ok, path1} = create_mount_point(user, "path1")
      {:ok, path2} = create_mount_point(user, "path2")

      {:ok, _, sa1} = ServiceAccounts.generate_service_account(user, path1.id, "sa1", nil)
      {:ok, _, _sa2} = ServiceAccounts.generate_service_account(user, path2.id, "sa2", nil)

      conn = get(conn, ~p"/api/service-accounts")

      assert %{"service_accounts" => accounts} = json_response(conn, 200)
      assert length(accounts) == 2

      # Check path is included
      account = Enum.find(accounts, &(&1["id"] == sa1.id))
      assert account["path"] == path1.full_path
      assert account["path_id"] == path1.id
    end

    test "returns empty list when user has no service accounts", %{conn: conn} do
      conn = get(conn, ~p"/api/service-accounts")

      assert %{"service_accounts" => []} = json_response(conn, 200)
    end
  end

  describe "DELETE /api/service-accounts/:id" do
    setup %{user: user, path: path} do
      {:ok, _, sa} = ServiceAccounts.generate_service_account(user, path.id, "test", nil)
      %{service_account: sa}
    end

    test "revokes service account", %{conn: conn, service_account: sa} do
      conn = delete(conn, ~p"/api/service-accounts/#{sa.id}")

      assert %{"message" => "Service account revoked successfully"} = json_response(conn, 200)

      # Verify it was revoked
      updated = ServiceAccounts.get_service_account(sa.id)
      assert updated.revoked_at != nil
    end

    test "returns 404 for non-existent service account", %{conn: conn} do
      fake_uuid = Ecto.UUID.generate()
      conn = delete(conn, ~p"/api/service-accounts/#{fake_uuid}")

      assert %{"error" => "Service account not found"} = json_response(conn, 404)
    end

    test "requires owner or maintainer role", %{user: user, path: path, service_account: sa} do
      viewer = Plugboard.AccountsFixtures.user_fixture()
      {:ok, _} = Paths.add_user_to_path(user.id, viewer.id, path.id, "viewer")

      conn = build_conn() |> log_in_user(viewer)
      conn = delete(conn, ~p"/api/service-accounts/#{sa.id}")

      assert %{"error" => "Requires owner or maintainer role"} = json_response(conn, 403)
    end

    test "allows maintainer to revoke", %{user: user, path: path, service_account: sa} do
      maintainer = Plugboard.AccountsFixtures.user_fixture()
      {:ok, _} = Paths.add_user_to_path(user.id, maintainer.id, path.id, "maintainer")

      conn = build_conn() |> log_in_user(maintainer)
      conn = delete(conn, ~p"/api/service-accounts/#{sa.id}")

      assert json_response(conn, 200)
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
