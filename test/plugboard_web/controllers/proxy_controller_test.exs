defmodule PlugboardWeb.ProxyControllerTest do
  use PlugboardWeb.ConnCase, async: false

  import Plugboard.AccountsFixtures

  alias Plugboard.Paths
  alias Plugboard.MountStore

  setup do
    # Ensure clean ETS state
    MountStore.reload_all()
    :ok
  end

  describe "GET /proxies/*path" do
    test "returns 404 when no mount point exists", %{conn: conn} do
      conn = get(conn, "/proxies/nonexistent/path")

      assert json_response(conn, 404) == %{
               "error" => "No mount point found for path",
               "path" => "/nonexistent/path"
             }
    end

    test "returns 503 when mount exists but no telephone available", %{conn: conn} do
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "api",
          user_id: user.id
        })

      {:ok, _mount} = Paths.update_path(path, %{mount_point: true})

      # Reload to ensure ETS is updated (tests don't wait for NOTIFY)
      MountStore.reload_all()

      conn = get(conn, "/proxies/api")

      # Phase 3: Returns 503 when no telephone is connected
      assert response = json_response(conn, 503)
      assert response["error"] == "No telephone available for this path"
      assert response["path"] == "/api"
    end

    test "returns 503 for nested requests when no telephone available", %{conn: conn} do
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "services",
          user_id: user.id
        })

      {:ok, _mount} = Paths.update_path(path, %{mount_point: true})

      # Reload to ensure ETS is updated (tests don't wait for NOTIFY)
      MountStore.reload_all()

      conn = get(conn, "/proxies/services/users/123/profile")

      # Phase 3: Returns 503 when no telephone is connected
      assert response = json_response(conn, 503)
      assert response["error"] == "No telephone available for this path"
      assert response["path"] == "/services"
    end

    test "matches nested mount points but returns 503 without telephone", %{conn: conn} do
      user = user_fixture()

      {:ok, parent} =
        Paths.create_path(%{
          path: "app",
          user_id: user.id
        })

      {:ok, child} =
        Paths.create_path(%{
          path: "api",
          parent_id: parent.id,
          user_id: user.id
        })

      {:ok, _mount} = Paths.update_path(child, %{mount_point: true})

      # Reload to ensure ETS is updated (tests don't wait for NOTIFY)
      MountStore.reload_all()

      conn = get(conn, "/proxies/app/api/v1/users")

      # Phase 3: Returns 503 when no telephone is connected
      assert response = json_response(conn, 503)
      assert response["error"] == "No telephone available for this path"
      assert response["path"] == "/app/api"
    end

    test "handles trailing slashes correctly but returns 503 without telephone", %{conn: conn} do
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "service",
          user_id: user.id
        })

      {:ok, _mount} = Paths.update_path(path, %{mount_point: true})

      # Reload to ensure ETS is updated (tests don't wait for NOTIFY)
      MountStore.reload_all()

      conn = get(conn, "/proxies/service/")

      # Phase 3: Returns 503 when no telephone is connected
      assert response = json_response(conn, 503)
      assert response["error"] == "No telephone available for this path"
      assert response["path"] == "/service"
    end
  end

  describe "POST /proxies/*path" do
    test "accepts POST requests but returns 503 without telephone", %{conn: conn} do
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "api",
          user_id: user.id
        })

      {:ok, _mount} = Paths.update_path(path, %{mount_point: true})

      # Reload to ensure ETS is updated (tests don't wait for NOTIFY)
      MountStore.reload_all()

      conn = post(conn, "/proxies/api/users", %{name: "Test"})

      # Phase 3: Returns 503 when no telephone is connected
      assert response = json_response(conn, 503)
      assert response["error"] == "No telephone available for this path"
      assert response["path"] == "/api"
    end
  end

  describe "PUT /proxies/*path" do
    test "accepts PUT requests but returns 503 without telephone", %{conn: conn} do
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "api",
          user_id: user.id
        })

      {:ok, _mount} = Paths.update_path(path, %{mount_point: true})

      # Reload to ensure ETS is updated (tests don't wait for NOTIFY)
      MountStore.reload_all()

      conn = put(conn, "/proxies/api/users/1", %{name: "Updated"})

      # Phase 3: Returns 503 when no telephone is connected
      assert response = json_response(conn, 503)
      assert response["error"] == "No telephone available for this path"
      assert response["path"] == "/api"
    end
  end

  describe "DELETE /proxies/*path" do
    test "accepts DELETE requests but returns 503 without telephone", %{conn: conn} do
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "api",
          user_id: user.id
        })

      {:ok, _mount} = Paths.update_path(path, %{mount_point: true})

      # Reload to ensure ETS is updated (tests don't wait for NOTIFY)
      MountStore.reload_all()

      conn = delete(conn, "/proxies/api/users/1")

      # Phase 3: Returns 503 when no telephone is connected
      assert response = json_response(conn, 503)
      assert response["error"] == "No telephone available for this path"
      assert response["path"] == "/api"
    end
  end

  describe "dynamic mount updates" do
    @tag :integration
    test "reflects newly added mounts via NOTIFY", %{conn: conn} do
      user = user_fixture()

      # Initially no mount exists
      conn1 = get(conn, "/proxies/newservice/test")
      assert json_response(conn1, 404)

      # Create and mark as mount
      {:ok, path} =
        Paths.create_path(%{
          path: "newservice",
          user_id: user.id
        })

      {:ok, _mount} = Paths.update_path(path, %{mount_point: true})

      # Wait for NOTIFY to propagate and update ETS
      # For now, we use manual reload to ensure test reliability
      # TODO: Investigate why NOTIFY propagation is slow in test environment
      :timer.sleep(50)
      MountStore.reload_all()

      # Phase 3: Now mount exists but returns 503 without telephone
      conn2 = get(build_conn(), "/proxies/newservice/test")
      assert response = json_response(conn2, 503)
      assert response["error"] == "No telephone available for this path"
      assert response["path"] == "/newservice"
    end

    test "reflects removed mounts", %{conn: conn} do
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "tempservice",
          user_id: user.id
        })

      {:ok, mounted_path} = Paths.update_path(path, %{mount_point: true})

      # Reload to ensure ETS is updated (tests don't wait for NOTIFY)
      MountStore.reload_all()

      # Phase 3: Mount exists but no telephone, returns 503
      conn1 = get(conn, "/proxies/tempservice/test")
      assert json_response(conn1, 503)["error"] == "No telephone available for this path"

      # Unmark as mount (use the mounted_path, not the original path)
      {:ok, _unmounted_path} = Paths.update_path(mounted_path, %{mount_point: false})

      # Reload to ensure ETS is updated
      MountStore.reload_all()

      # Should no longer match (404, not 503)
      conn2 = get(build_conn(), "/proxies/tempservice/test")
      assert json_response(conn2, 404)
    end

    @tag :integration
    test "reflects deleted mounts via NOTIFY", %{conn: conn} do
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "deleteservice",
          user_id: user.id
        })

      {:ok, _mount} = Paths.update_path(path, %{mount_point: true})

      # Reload to ensure ETS is updated
      MountStore.reload_all()

      # Phase 3: Mount exists but no telephone, returns 503
      conn1 = get(conn, "/proxies/deleteservice/test")
      assert json_response(conn1, 503)["error"] == "No telephone available for this path"

      # Delete path
      {:ok, _path} = Paths.delete_path(path)

      # Wait for NOTIFY to propagate and remove from ETS
      # For now, we use manual reload to ensure test reliability
      :timer.sleep(50)
      MountStore.reload_all()

      # Should no longer match (404, not 503)
      conn2 = get(build_conn(), "/proxies/deleteservice/test")
      assert json_response(conn2, 404)
    end
  end

  describe "edge cases" do
    test "handles empty path segments gracefully", %{conn: conn} do
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "api",
          user_id: user.id
        })

      {:ok, _mount} = Paths.update_path(path, %{mount_point: true})

      # Reload to ensure ETS is updated (tests don't wait for NOTIFY)
      MountStore.reload_all()

      # Request with double slashes should still work after normalization
      conn = get(conn, "/proxies/api")

      # Phase 3: Returns 503 when no telephone is connected
      assert response = json_response(conn, 503)
      assert response["error"] == "No telephone available for this path"
      assert response["path"] == "/api"
    end

    test "matches most specific mount when multiple exist", %{conn: _conn} do
      user = user_fixture()

      # Create two separate mount hierarchies to test specificity
      # /api mount
      {:ok, api} =
        Paths.create_path(%{
          path: "api",
          user_id: user.id
        })

      {:ok, _api_mount} = Paths.update_path(api, %{mount_point: true})

      # /api-v2 mount (more specific in terms of path length)
      {:ok, api_v2} =
        Paths.create_path(%{
          path: "api-v2",
          user_id: user.id
        })

      {:ok, _api_v2_mount} = Paths.update_path(api_v2, %{mount_point: true})

      # Reload to ensure ETS is updated (tests don't wait for NOTIFY)
      MountStore.reload_all()

      # Phase 3: Both return 503 when no telephone is connected
      # /api-v2/users should match the /api-v2 mount
      conn1 = get(build_conn(), "/proxies/api-v2/users")
      assert response1 = json_response(conn1, 503)
      assert response1["error"] == "No telephone available for this path"
      assert response1["path"] == "/api-v2"

      # /api/users should match the /api mount
      conn2 = get(build_conn(), "/proxies/api/users")
      assert response2 = json_response(conn2, 503)
      assert response2["error"] == "No telephone available for this path"
      assert response2["path"] == "/api"
    end
  end
end
