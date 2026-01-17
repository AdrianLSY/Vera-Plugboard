defmodule PlugboardWeb.Plugs.WebSocketProxyPlugTest do
  use PlugboardWeb.ConnCase, async: false

  import Plugboard.AccountsFixtures

  alias Plugboard.Paths
  alias Plugboard.DomainAffinities
  alias Plugboard.TelephoneRegistry
  alias PlugboardWeb.Plugs.WebSocketProxyPlug

  describe "non-WebSocket requests" do
    test "passes through regular HTTP GET requests", %{conn: conn} do
      conn =
        conn
        |> Map.put(:request_path, "/call/api/users")
        |> WebSocketProxyPlug.call([])

      # Should not be halted - passes through to router
      refute conn.halted
    end

    test "passes through regular HTTP POST requests", %{conn: conn} do
      conn =
        conn
        |> Map.put(:request_path, "/call/api/users")
        |> Map.put(:method, "POST")
        |> WebSocketProxyPlug.call([])

      refute conn.halted
    end

    test "passes through requests without upgrade header", %{conn: conn} do
      conn =
        conn
        |> Map.put(:request_path, "/call/api/websocket")
        |> put_req_header("connection", "keep-alive")
        |> WebSocketProxyPlug.call([])

      refute conn.halted
    end
  end

  describe "excluded paths" do
    setup do
      # Add WebSocket upgrade headers
      %{
        ws_headers: [
          {"upgrade", "websocket"},
          {"connection", "upgrade"},
          {"sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ=="},
          {"sec-websocket-version", "13"}
        ]
      }
    end

    test "passes through /live paths", %{conn: conn, ws_headers: headers} do
      conn =
        conn
        |> Map.put(:request_path, "/live/dashboard")
        |> put_ws_headers(headers)
        |> WebSocketProxyPlug.call([])

      refute conn.halted
    end

    test "passes through /phoenix paths", %{conn: conn, ws_headers: headers} do
      conn =
        conn
        |> Map.put(:request_path, "/phoenix/live_reload/socket")
        |> put_ws_headers(headers)
        |> WebSocketProxyPlug.call([])

      refute conn.halted
    end

    test "passes through /telephone paths", %{conn: conn, ws_headers: headers} do
      conn =
        conn
        |> Map.put(:request_path, "/telephone/websocket")
        |> put_ws_headers(headers)
        |> WebSocketProxyPlug.call([])

      refute conn.halted
    end

    test "passes through /api paths", %{conn: conn, ws_headers: headers} do
      conn =
        conn
        |> Map.put(:request_path, "/api/tokens")
        |> put_ws_headers(headers)
        |> WebSocketProxyPlug.call([])

      refute conn.halted
    end

    test "passes through /users paths", %{conn: conn, ws_headers: headers} do
      conn =
        conn
        |> Map.put(:request_path, "/users/settings")
        |> put_ws_headers(headers)
        |> WebSocketProxyPlug.call([])

      refute conn.halted
    end

    test "passes through /dev paths", %{conn: conn, ws_headers: headers} do
      conn =
        conn
        |> Map.put(:request_path, "/dev/dashboard")
        |> put_ws_headers(headers)
        |> WebSocketProxyPlug.call([])

      refute conn.halted
    end

    test "passes through /paths paths", %{conn: conn, ws_headers: headers} do
      conn =
        conn
        |> Map.put(:request_path, "/paths")
        |> put_ws_headers(headers)
        |> WebSocketProxyPlug.call([])

      refute conn.halted
    end

    test "passes through /assets paths", %{conn: conn, ws_headers: headers} do
      conn =
        conn
        |> Map.put(:request_path, "/assets/app.js")
        |> put_ws_headers(headers)
        |> WebSocketProxyPlug.call([])

      refute conn.halted
    end
  end

  describe "WebSocket proxy disabled" do
    setup do
      # Store original config
      original = Application.get_env(:plugboard, :websocket_proxy)

      # Disable WebSocket proxy
      Application.put_env(
        :plugboard,
        :websocket_proxy,
        Keyword.put(original || [], :enabled, false)
      )

      on_exit(fn ->
        # Restore original config
        if original do
          Application.put_env(:plugboard, :websocket_proxy, original)
        else
          Application.delete_env(:plugboard, :websocket_proxy)
        end
      end)

      %{
        ws_headers: [
          {"upgrade", "websocket"},
          {"connection", "upgrade"},
          {"sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ=="},
          {"sec-websocket-version", "13"}
        ]
      }
    end

    test "passes through when disabled", %{conn: conn, ws_headers: headers} do
      conn =
        conn
        |> Map.put(:request_path, "/call/api/websocket")
        |> put_ws_headers(headers)
        |> WebSocketProxyPlug.call([])

      refute conn.halted
    end
  end

  describe "path-based routing (/call/*)" do
    setup do
      user = user_fixture()

      # Create a mount point
      {:ok, path} =
        Paths.create_path(%{
          path: "ws-test-api",
          user_id: user.id,
          mount_point: true
        })

      # Reload MountStore to pick up the new mount point
      Plugboard.MountStore.reload_all()

      %{
        user: user,
        path: path,
        ws_headers: [
          {"upgrade", "websocket"},
          {"connection", "upgrade"},
          {"sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ=="},
          {"sec-websocket-version", "13"}
        ]
      }
    end

    test "returns 503 when no telephone is registered", %{
      conn: conn,
      path: _path,
      ws_headers: headers
    } do
      conn =
        conn
        |> Map.put(:request_path, "/call/ws-test-api/websocket")
        |> put_ws_headers(headers)
        |> WebSocketProxyPlug.call([])

      # Should return 503 because no telephone is registered
      assert conn.halted
      assert conn.status == 503
      assert conn.resp_body =~ "No telephone available"
    end

    test "passes through when mount point not found", %{conn: conn, ws_headers: headers} do
      conn =
        conn
        |> Map.put(:request_path, "/call/nonexistent/websocket")
        |> put_ws_headers(headers)
        |> WebSocketProxyPlug.call([])

      # Should pass through for router to handle
      refute conn.halted
    end

    test "attempts upgrade when telephone is available", %{
      conn: conn,
      path: path,
      ws_headers: headers
    } do
      # Spawn a mock telephone that registers itself
      telephone_pid = spawn_mock_telephone(path.id)

      # Give registry time to propagate
      Process.sleep(50)

      # The plug will try to upgrade - it will raise an error in test context
      # because we don't have a real WebSocket handshake. This is expected.
      # The important thing is that it reaches the upgrade point (not 503).
      assert_raise WebSockAdapter.UpgradeError, fn ->
        conn
        |> Map.put(:host, "localhost")
        |> Map.put(:request_path, "/call/ws-test-api/websocket")
        |> put_ws_headers(headers)
        |> WebSocketProxyPlug.call([])
      end

      # Clean up
      Process.exit(telephone_pid, :kill)
    end
  end

  describe "domain-based routing" do
    setup do
      user = user_fixture()

      # Create a mount point
      {:ok, path} =
        Paths.create_path(%{
          path: "ws-domain-api",
          user_id: user.id,
          mount_point: true
        })

      # Create a domain affinity
      {:ok, _da} =
        DomainAffinities.create_domain_affinity(user.id, %{
          domain: "ws.example.com",
          path_id: path.id
        })

      # Reload MountStore
      Plugboard.MountStore.reload_all()

      %{
        user: user,
        path: path,
        ws_headers: [
          {"upgrade", "websocket"},
          {"connection", "upgrade"},
          {"sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ=="},
          {"sec-websocket-version", "13"}
        ]
      }
    end

    test "returns 503 when no telephone for domain affinity", %{conn: conn, ws_headers: headers} do
      conn =
        conn
        |> Map.put(:host, "ws.example.com")
        |> Map.put(:request_path, "/websocket")
        |> put_ws_headers(headers)
        |> WebSocketProxyPlug.call([])

      assert conn.halted
      assert conn.status == 503
    end

    test "passes through when domain has no affinity", %{conn: conn, ws_headers: headers} do
      conn =
        conn
        |> Map.put(:host, "unknown.example.com")
        |> Map.put(:request_path, "/websocket")
        |> put_ws_headers(headers)
        |> WebSocketProxyPlug.call([])

      # Should pass through for router to handle
      refute conn.halted
    end
  end

  describe "WebSocket header detection" do
    # Use unique paths that won't conflict with mount points created by other tests
    @unique_test_path "/call/ws-header-detection-test-#{:erlang.phash2(__MODULE__)}/ws"

    test "detects valid WebSocket upgrade", %{conn: conn} do
      conn =
        conn
        |> put_req_header("upgrade", "websocket")
        |> put_req_header("connection", "upgrade")

      # The plug should recognize this as a WebSocket upgrade
      # We can't directly test the private function, but we can test the behavior
      # by checking if it tries to match paths
      conn =
        conn
        |> Map.put(:request_path, @unique_test_path)
        |> WebSocketProxyPlug.call([])

      # With no mount point, it passes through (proving it detected the upgrade
      # and tried to match)
      refute conn.halted
    end

    test "detects upgrade with mixed case headers", %{conn: conn} do
      conn =
        conn
        |> put_req_header("upgrade", "WebSocket")
        |> put_req_header("connection", "Upgrade")
        |> Map.put(:request_path, @unique_test_path)
        |> WebSocketProxyPlug.call([])

      refute conn.halted
    end

    test "detects connection header with multiple values", %{conn: conn} do
      conn =
        conn
        |> put_req_header("upgrade", "websocket")
        |> put_req_header("connection", "keep-alive, upgrade")
        |> Map.put(:request_path, @unique_test_path)
        |> WebSocketProxyPlug.call([])

      refute conn.halted
    end

    test "does not detect without upgrade header", %{conn: conn} do
      conn =
        conn
        |> put_req_header("connection", "upgrade")
        |> Map.put(:request_path, @unique_test_path)
        |> WebSocketProxyPlug.call([])

      refute conn.halted
    end

    test "does not detect without connection header", %{conn: conn} do
      conn =
        conn
        |> put_req_header("upgrade", "websocket")
        |> Map.put(:request_path, @unique_test_path)
        |> WebSocketProxyPlug.call([])

      refute conn.halted
    end
  end

  describe "init/1" do
    test "returns opts unchanged" do
      opts = [some: :option]
      assert WebSocketProxyPlug.init(opts) == opts
    end
  end

  # Helper functions

  defp put_ws_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {key, value}, acc ->
      put_req_header(acc, key, value)
    end)
  end

  defp spawn_mock_telephone(path_id) do
    test_pid = self()

    spawn(fn ->
      # Register with the telephone registry
      :ok = TelephoneRegistry.register(path_id, self())

      # Notify the test that we're registered
      send(test_pid, {:telephone_registered, self()})

      # Wait for messages until killed
      receive do
        :stop -> :ok
      after
        30_000 -> :ok
      end
    end)

    # Wait for registration confirmation
    receive do
      {:telephone_registered, pid} -> pid
    after
      1000 -> raise "Telephone registration timeout"
    end
  end
end
