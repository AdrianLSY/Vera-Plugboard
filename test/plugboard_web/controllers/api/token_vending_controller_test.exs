defmodule PlugboardWeb.Api.TokenVendingControllerTest do
  use PlugboardWeb.ConnCase

  alias Plugboard.ServiceAccounts
  alias Plugboard.TelephoneTokens
  alias Plugboard.Paths

  setup do
    user = Plugboard.AccountsFixtures.user_fixture()
    {:ok, path} = create_mount_point(user)
    {:ok, api_key, service_account} = ServiceAccounts.generate_service_account(user, path.id, "test-sa", "Test")

    %{user: user, path: path, api_key: api_key, service_account: service_account}
  end

  describe "POST /api/token-vending/generate" do
    test "generates token with valid API key", %{conn: conn, api_key: api_key, path: path} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{api_key}")
        |> put_req_header("content-type", "application/json")
        |> post("/api/token-vending/generate", %{})

      assert %{
               "token" => token,
               "token_id" => token_id,
               "path" => path_str,
               "expires_at" => _,
               "expires_in" => expires_in
             } = json_response(conn, 201)

      # Verify JWT format
      assert String.starts_with?(token, "eyJ")
      assert is_binary(token_id)
      assert path_str == path.full_path
      assert expires_in > 0

      # Verify token was created in database
      token_record = TelephoneTokens.get_token(token_id)
      assert token_record != nil
      assert token_record.path_id == path.id
    end

    test "generates token with instance_id in description", %{conn: conn, api_key: api_key} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{api_key}")
        |> put_req_header("content-type", "application/json")
        |> post("/api/token-vending/generate", %{"instance_id" => "pod-12345"})

      assert %{"token_id" => token_id} = json_response(conn, 201)

      # Check description includes instance ID
      token = TelephoneTokens.get_token(token_id)
      assert token.description =~ "pod-12345"
    end

    test "generates token with custom description", %{conn: conn, api_key: api_key} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{api_key}")
        |> put_req_header("content-type", "application/json")
        |> post("/api/token-vending/generate", %{"description" => "Custom desc"})

      assert %{"token_id" => token_id} = json_response(conn, 201)

      token = TelephoneTokens.get_token(token_id)
      assert token.description == "Custom desc"
    end

    test "accepts lowercase 'bearer' in authorization header", %{conn: conn, api_key: api_key} do
      conn =
        conn
        |> put_req_header("authorization", "bearer #{api_key}")
        |> put_req_header("content-type", "application/json")
        |> post("/api/token-vending/generate", %{})

      assert json_response(conn, 201)
    end

    test "rejects request without authorization header", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/token-vending/generate", %{})

      assert %{"error" => "Missing Authorization header"} = json_response(conn, 401)
    end

    test "rejects request with invalid authorization format", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "InvalidFormat")
        |> put_req_header("content-type", "application/json")
        |> post("/api/token-vending/generate", %{})

      assert %{"error" => error} = json_response(conn, 401)
      assert error =~ "Invalid Authorization header format"
    end

    test "rejects invalid API key", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer sa_live_invalid_key")
        |> put_req_header("content-type", "application/json")
        |> post("/api/token-vending/generate", %{})

      assert %{"error" => "Invalid or revoked service account API key"} = json_response(conn, 401)
    end

    test "rejects revoked service account", %{conn: conn, api_key: api_key, service_account: sa} do
      # Revoke the service account
      {:ok, _} = ServiceAccounts.revoke_service_account(sa.id)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{api_key}")
        |> put_req_header("content-type", "application/json")
        |> post("/api/token-vending/generate", %{})

      assert %{"error" => "Invalid or revoked service account API key"} = json_response(conn, 401)
    end

    test "rejects when path is deleted", %{conn: conn, api_key: api_key, path: path} do
      # Delete the path
      {:ok, _} = Paths.delete_path(path)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{api_key}")
        |> put_req_header("content-type", "application/json")
        |> post("/api/token-vending/generate", %{})

      assert %{"error" => "Invalid or revoked service account API key"} = json_response(conn, 401)
    end

    test "rejects when requesting different path_id", %{conn: conn, api_key: api_key, user: user} do
      # Create another path
      {:ok, other_path} = create_mount_point(user, "other")

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{api_key}")
        |> put_req_header("content-type", "application/json")
        |> post("/api/token-vending/generate", %{"path_id" => other_path.id})

      assert %{
               "error" => "Service account does not have access to this path",
               "allowed_path_id" => _,
               "requested_path_id" => _
             } = json_response(conn, 403)
    end

    test "marks service account as used", %{conn: conn, api_key: api_key, service_account: sa} do
      # Initially not used
      assert sa.last_used_at == nil

      conn
      |> put_req_header("authorization", "Bearer #{api_key}")
      |> put_req_header("content-type", "application/json")
      |> post("/api/token-vending/generate", %{})

      # Check last_used_at was updated
      updated_sa = ServiceAccounts.get_service_account(sa.id)
      assert updated_sa.last_used_at != nil
    end

    test "handles path that is not a mount point", %{conn: conn, user: user, api_key: _old_key} do
      # Create a non-mount path
      {:ok, non_mount_path} =
        Paths.create_path(%{
          path: "non-mount-#{System.unique_integer([:positive])}",
          user_id: user.id,
          parent_id: nil,
          mount_point: false
        })

      # Create service account for non-mount path (this should succeed)
      {:ok, api_key, _sa} = ServiceAccounts.generate_service_account(user, non_mount_path.id, "test2", nil)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{api_key}")
        |> put_req_header("content-type", "application/json")
        |> post("/api/token-vending/generate", %{})

      # Should fail during token generation because path is not a mount point
      # The validation happens during api_key validation where it checks path validity
      assert %{"error" => error} = json_response(conn, 401)
      assert error =~ "Invalid or revoked"
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
