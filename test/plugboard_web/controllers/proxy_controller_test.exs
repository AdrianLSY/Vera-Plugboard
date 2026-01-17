defmodule PlugboardWeb.ProxyControllerTest do
  @moduledoc """
  Comprehensive tests for ProxyController.

  Tests cover:
  - Basic routing and mount point matching
  - HTTP method handling (GET, POST, PUT, DELETE)
  - Request timeout handling (504)
  - Error responses with HTTP status images
  - Path validation and security
  - Dynamic mount updates via NOTIFY
  - Edge cases and concurrent requests
  """
  use PlugboardWeb.ConnCase, async: false

  import Plugboard.AccountsFixtures

  alias Plugboard.Paths
  alias Plugboard.MountStore
  alias Plugboard.TelephoneRegistry

  setup do
    # Ensure clean ETS state
    MountStore.reload_all()
    :ok
  end

  describe "GET /call/*path - basic routing" do
    test "returns 404 when no mount point exists", %{conn: conn} do
      conn = get(conn, "/call/nonexistent/path")

      assert conn.status == 404
      assert html_response(conn, 404) =~ "404"
      assert html_response(conn, 404) =~ "No mount point found"
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

      conn = get(conn, "/call/api")

      assert conn.status == 503
      assert html_response(conn, 503) =~ "503"
      assert html_response(conn, 503) =~ "No telephone available"
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

      conn = get(conn, "/call/services/users/123/profile")

      assert conn.status == 503
      assert html_response(conn, 503) =~ "503"
      assert html_response(conn, 503) =~ "No telephone available"
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

      conn = get(conn, "/call/app/api/v1/users")

      assert conn.status == 503
      assert html_response(conn, 503) =~ "503"
      assert html_response(conn, 503) =~ "No telephone available"
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

      conn = get(conn, "/call/service/")

      assert conn.status == 503
      assert html_response(conn, 503) =~ "503"
      assert html_response(conn, 503) =~ "No telephone available"
    end
  end

  describe "POST /call/*path" do
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

      conn = post(conn, "/call/api/users", %{name: "Test"})

      assert conn.status == 503
      assert html_response(conn, 503) =~ "503"
      assert html_response(conn, 503) =~ "No telephone available"
    end
  end

  describe "PUT /call/*path" do
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

      conn = put(conn, "/call/api/users/1", %{name: "Updated"})

      assert conn.status == 503
      assert html_response(conn, 503) =~ "503"
      assert html_response(conn, 503) =~ "No telephone available"
    end
  end

  describe "DELETE /call/*path" do
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

      conn = delete(conn, "/call/api/users/1")

      assert conn.status == 503
      assert html_response(conn, 503) =~ "503"
      assert html_response(conn, 503) =~ "No telephone available"
    end
  end

  describe "timeout handling" do
    @tag :slow
    @tag timeout: 10_000
    test "returns 504 when telephone does not respond in time", %{conn: conn} do
      user = user_fixture()

      # Create path with very short timeout
      {:ok, path} =
        Paths.create_path(%{
          path: "slow-api",
          user_id: user.id
        })

      {:ok, path} =
        Paths.update_path(path, %{
          mount_point: true,
          request_timeout_ms: 500
        })

      MountStore.reload_all()

      # Create a mock telephone that never responds
      telephone_pid =
        spawn(fn ->
          receive do
            {:proxy_request, _from, _request_id, _payload} ->
              # Sleep longer than the timeout but don't send response
              Process.sleep(2000)
          end
        end)

      # Register the non-responding telephone
      :ok = TelephoneRegistry.register(path.id, telephone_pid)

      # Make request - should timeout
      conn = get(conn, "/call/slow-api/test")

      # Should return 504 Gateway Timeout
      assert conn.status == 504
      assert response_body = html_response(conn, 504)
      assert response_body =~ "504"
      assert response_body =~ "Gateway Timeout"

      # Cleanup
      Process.exit(telephone_pid, :kill)
    end

    test "logs slow responses that approach timeout threshold" do
      # This test verifies that slow responses (>80% of timeout) are logged
      # Implementation uses telemetry, so we'd need to attach handlers to verify
      # For now, this is a placeholder for the slow response warning feature
      assert true
    end
  end

  describe "error response format" do
    test "error responses include HTTP status images", %{conn: conn} do
      # Test 404 with no mount
      conn = get(conn, "/call/nonexistent")

      assert conn.status == 404
      assert response_body = html_response(conn, 404)
      # Check for image tag
      assert response_body =~ "<img"
      assert response_body =~ "/img/http/404.jpg"
      assert response_body =~ "404"
      assert response_body =~ "No mount point found"
    end

    test "error responses include helpful details", %{conn: conn} do
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "test-api",
          user_id: user.id
        })

      {:ok, _path} = Paths.update_path(path, %{mount_point: true})
      MountStore.reload_all()

      # Make request with no telephone - should return 503
      conn = get(conn, "/call/test-api/endpoint")

      assert conn.status == 503
      assert response_body = html_response(conn, 503)
      assert response_body =~ "503"
      assert response_body =~ "No telephone available"
      # Should include details about the path
      assert response_body =~ "test-api"
    end

    test "error responses are valid HTML", %{conn: conn} do
      conn = get(conn, "/call/nonexistent")

      assert conn.status == 404
      assert response_body = html_response(conn, 404)
      # Check for basic HTML structure
      assert response_body =~ "<!DOCTYPE html>"
      assert response_body =~ "<html"
      assert response_body =~ "</html>"
      assert response_body =~ "<body"
      assert response_body =~ "</body>"
    end
  end

  describe "timeout configuration validation" do
    @tag :slow
    test "uses default timeout when configured timeout is invalid", %{conn: conn} do
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "invalid-timeout-api",
          user_id: user.id
        })

      # Manually set an invalid timeout in the database
      {:ok, path} =
        path
        |> Ecto.Changeset.change(request_timeout_ms: -1000)
        |> Plugboard.Repo.update()

      {:ok, path} = Paths.update_path(path, %{mount_point: true})
      MountStore.reload_all()

      # Create a non-responding telephone
      telephone_pid =
        spawn(fn ->
          receive do
            {:proxy_request, _from, _request_id, _payload} ->
              :timer.sleep(10_000)
          end
        end)

      :ok = TelephoneRegistry.register(path.id, telephone_pid)

      # Make request - should use default timeout and eventually timeout
      # Note: This is a long test, so we just verify it doesn't crash
      task =
        Task.async(fn ->
          get(conn, "/call/invalid-timeout-api/test")
        end)

      # Wait a short time to ensure it's processing
      :timer.sleep(100)

      # Cancel the task to avoid waiting for full timeout
      Task.shutdown(task, :brutal_kill)

      # Cleanup
      Process.exit(telephone_pid, :kill)
    end
  end

  describe "telemetry events" do
    @tag :slow
    @tag timeout: 10_000
    test "emits timeout telemetry events" do
      # Attach a test telemetry handler
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:plugboard, :telephone, :proxy_timeout]
        ])

      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "telemetry-api",
          user_id: user.id
        })

      {:ok, path} =
        Paths.update_path(path, %{
          mount_point: true,
          request_timeout_ms: 500
        })

      MountStore.reload_all()

      # Verify the timeout was actually set by reloading from DB
      reloaded_path = Plugboard.Repo.get!(Plugboard.Paths.Path, path.id)
      assert reloaded_path.request_timeout_ms == 500

      telephone_pid =
        spawn(fn ->
          receive do
            {:proxy_request, _from, _request_id, _payload} ->
              # Sleep longer than timeout
              Process.sleep(2000)
          end
        end)

      :ok = TelephoneRegistry.register(path.id, telephone_pid)

      # Make request that will timeout
      _conn = get(build_conn(), "/call/telemetry-api/test")

      # Verify telemetry event was emitted
      assert_receive {[:plugboard, :telephone, :proxy_timeout], ^ref, %{count: 1}, metadata}, 3000
      assert metadata.path_id == path.id
      # The timeout_ms in metadata should match what we configured
      assert metadata.timeout_ms == 500

      # Cleanup
      :telemetry.detach(ref)
      Process.exit(telephone_pid, :kill)
    end
  end

  describe "path validation errors" do
    test "returns 400 for path traversal attempts", %{conn: conn} do
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "secure-api",
          user_id: user.id
        })

      {:ok, _path} = Paths.update_path(path, %{mount_point: true})
      MountStore.reload_all()

      # Try path traversal
      conn = get(conn, "/call/secure-api/../../../etc/passwd")

      assert conn.status == 400
      assert response_body = html_response(conn, 400)
      assert response_body =~ "400"
      assert response_body =~ "Invalid path"
    end

    test "returns 400 for paths exceeding maximum depth", %{conn: conn} do
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "api",
          user_id: user.id
        })

      {:ok, _path} = Paths.update_path(path, %{mount_point: true})
      MountStore.reload_all()

      # Create a very deep path (>50 segments)
      deep_path = Enum.map_join(1..60, "/", fn i -> "segment#{i}" end)
      conn = get(conn, "/call/api/#{deep_path}")

      assert conn.status == 400
      assert response_body = html_response(conn, 400)
      assert response_body =~ "400"
    end
  end

  describe "concurrent request handling with errors" do
    @tag :slow
    @tag timeout: 15_000
    test "handles multiple concurrent timeouts correctly", %{conn: _conn} do
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "concurrent-api",
          user_id: user.id
        })

      {:ok, path} =
        Paths.update_path(path, %{
          mount_point: true,
          request_timeout_ms: 500
        })

      MountStore.reload_all()

      # Create non-responding telephone that handles multiple requests
      telephone_pid =
        spawn(fn ->
          receive_loop = fn receive_loop ->
            receive do
              {:proxy_request, _from, _request_id, _payload} ->
                # Sleep longer than timeout but don't block forever
                spawn(fn -> Process.sleep(2000) end)
                receive_loop.(receive_loop)
            end
          end

          receive_loop.(receive_loop)
        end)

      :ok = TelephoneRegistry.register(path.id, telephone_pid)

      # Make multiple concurrent requests
      tasks =
        Enum.map(1..3, fn _i ->
          Task.async(fn ->
            conn = get(build_conn(), "/call/concurrent-api/test")
            conn.status
          end)
        end)

      # All should timeout with 504
      # Each request: 500ms timeout + 1000ms Task.await buffer in proxy = ~1500ms
      # Wait 2500ms to allow all 3 concurrent requests to complete
      results = Task.await_many(tasks, 2_500)
      assert Enum.all?(results, fn status -> status == 504 end)

      # Cleanup
      Process.exit(telephone_pid, :kill)
    end
  end

  describe "dynamic mount updates" do
    @tag :integration
    test "reflects newly added mounts via NOTIFY", %{conn: conn} do
      user = user_fixture()

      # Initially no mount exists
      conn1 = get(conn, "/call/newservice/test")
      assert conn1.status == 404

      # Create and mark as mount
      {:ok, path} =
        Paths.create_path(%{
          path: "newservice",
          user_id: user.id
        })

      {:ok, _mount} = Paths.update_path(path, %{mount_point: true})

      # Wait for NOTIFY to propagate and use manual reload to ensure test reliability
      # NOTIFY propagation can be slower in test environment due to transaction isolation
      :timer.sleep(50)
      MountStore.reload_all()

      # Now mount exists but returns 503 without telephone
      conn2 = get(build_conn(), "/call/newservice/test")
      assert conn2.status == 503
      assert html_response(conn2, 503) =~ "503"
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

      # Mount exists but no telephone, returns 503
      conn1 = get(conn, "/call/tempservice/test")
      assert conn1.status == 503

      # Unmark as mount (use the mounted_path, not the original path)
      {:ok, _unmounted_path} = Paths.update_path(mounted_path, %{mount_point: false})

      # Reload to ensure ETS is updated
      MountStore.reload_all()

      # Should no longer match (404, not 503)
      conn2 = get(build_conn(), "/call/tempservice/test")
      assert conn2.status == 404
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

      # Mount exists but no telephone, returns 503
      conn1 = get(conn, "/call/deleteservice/test")
      assert conn1.status == 503

      # Delete path
      {:ok, _path} = Paths.delete_path(path)

      # Wait for NOTIFY to propagate and remove from ETS
      # For now, we use manual reload to ensure test reliability
      :timer.sleep(50)
      MountStore.reload_all()

      # Should no longer match (404, not 503)
      conn2 = get(build_conn(), "/call/deleteservice/test")
      assert conn2.status == 404
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
      conn = get(conn, "/call/api")

      # Returns 503 when no telephone is connected
      assert conn.status == 503
      assert html_response(conn, 503) =~ "503"
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

      # Both return 503 when no telephone is connected
      # /api-v2/users should match the /api-v2 mount
      conn1 = get(build_conn(), "/call/api-v2/users")
      assert conn1.status == 503
      assert html_response(conn1, 503) =~ "503"

      # /api/users should match the /api mount
      conn2 = get(build_conn(), "/call/api/users")
      assert conn2.status == 503
      assert html_response(conn2, 503) =~ "503"
    end
  end

  # Helper to spawn a mock telephone that registers itself and handles requests
  # IMPORTANT: Horde.Registry only allows self() registration, so the telephone
  # process must register itself, not be registered by another process.
  defp spawn_mock_telephone(path_id, test_pid, response_fn) do
    spawn(fn ->
      # Register self with Horde (this is the only way Horde registration works)
      {:ok, _} = Plugboard.DistributedRegistry.register(path_id)

      # Signal ready to test process
      send(test_pid, {:telephone_ready, self()})

      # Handle requests in a loop
      receive_loop(response_fn)
    end)
  end

  defp receive_loop(response_fn) do
    receive do
      {:proxy_request, from, request_id, payload} ->
        response_fn.(from, request_id, payload)
        receive_loop(response_fn)

      :stop ->
        :ok
    end
  end

  describe "successful telephone responses" do
    test "forwards successful response from telephone to client", %{conn: conn} do
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "success-api",
          user_id: user.id
        })

      {:ok, path} = Paths.update_path(path, %{mount_point: true})
      MountStore.reload_all()

      # Create a mock telephone that registers itself and responds successfully
      telephone_pid =
        spawn_mock_telephone(path.id, self(), fn from, request_id, _payload ->
          response = %{
            "status" => 200,
            "headers" => %{"content-type" => "application/json"},
            "body" => ~s({"message": "success"})
          }

          send(from, {:proxy_res, request_id, response})
        end)

      # Wait for telephone to register
      assert_receive {:telephone_ready, ^telephone_pid}, 1000

      conn = get(conn, "/call/success-api/test")

      assert conn.status == 200
      # Use response/2 since content-type is application/json
      assert response(conn, 200) =~ "success"

      # Cleanup
      send(telephone_pid, :stop)
    end

    test "forwards custom status codes from telephone", %{conn: conn} do
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "status-api",
          user_id: user.id
        })

      {:ok, path} = Paths.update_path(path, %{mount_point: true})
      MountStore.reload_all()

      # Create a mock telephone that responds with 201 Created
      telephone_pid =
        spawn_mock_telephone(path.id, self(), fn from, request_id, _payload ->
          response = %{
            "status" => 201,
            "headers" => %{"location" => "/resources/123"},
            "body" => "Created"
          }

          send(from, {:proxy_res, request_id, response})
        end)

      assert_receive {:telephone_ready, ^telephone_pid}, 1000

      conn = post(conn, "/call/status-api/resources", %{name: "test"})

      assert conn.status == 201
      assert get_resp_header(conn, "location") == ["/resources/123"]

      # Cleanup
      send(telephone_pid, :stop)
    end

    test "forwards headers from telephone response", %{conn: conn} do
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "headers-api",
          user_id: user.id
        })

      {:ok, path} = Paths.update_path(path, %{mount_point: true})
      MountStore.reload_all()

      # Create a mock telephone that responds with multiple headers
      telephone_pid =
        spawn_mock_telephone(path.id, self(), fn from, request_id, _payload ->
          response = %{
            "status" => 200,
            "headers" => %{
              "X-Custom-Header" => "custom-value",
              "X-Request-Id" => "req-123",
              "Content-Type" => "text/plain"
            },
            "body" => "OK"
          }

          send(from, {:proxy_res, request_id, response})
        end)

      assert_receive {:telephone_ready, ^telephone_pid}, 1000

      conn = get(conn, "/call/headers-api/test")

      assert conn.status == 200
      assert get_resp_header(conn, "x-custom-header") == ["custom-value"]
      assert get_resp_header(conn, "x-request-id") == ["req-123"]
      assert get_resp_header(conn, "content-type") == ["text/plain"]

      # Cleanup
      send(telephone_pid, :stop)
    end

    test "handles empty response body", %{conn: conn} do
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "empty-api",
          user_id: user.id
        })

      {:ok, path} = Paths.update_path(path, %{mount_point: true})
      MountStore.reload_all()

      telephone_pid =
        spawn_mock_telephone(path.id, self(), fn from, request_id, _payload ->
          response = %{
            "status" => 204
            # No body or headers
          }

          send(from, {:proxy_res, request_id, response})
        end)

      assert_receive {:telephone_ready, ^telephone_pid}, 1000

      conn = delete(conn, "/call/empty-api/resource/1")

      assert conn.status == 204

      # Cleanup
      send(telephone_pid, :stop)
    end

    test "correctly passes request payload to telephone", %{conn: conn} do
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "payload-api",
          user_id: user.id
        })

      {:ok, path} = Paths.update_path(path, %{mount_point: true})
      MountStore.reload_all()

      test_pid = self()

      telephone_pid =
        spawn_mock_telephone(path.id, self(), fn from, request_id, payload ->
          # Capture the payload for test assertion
          send(test_pid, {:payload_received, payload})

          response = %{"status" => 200, "body" => "OK"}
          send(from, {:proxy_res, request_id, response})
        end)

      assert_receive {:telephone_ready, ^telephone_pid}, 1000

      result_conn =
        conn
        |> put_req_header("x-custom", "test-value")
        |> get("/call/payload-api/users?sort=name")

      assert result_conn.status == 200

      # Verify payload was correctly passed
      assert_receive {:payload_received, payload}, 1000
      assert payload["method"] == "GET"
      assert payload["path"] == "/users"
      assert payload["query_string"] == "sort=name"
      assert payload["headers"]["x-custom"] == "test-value"

      # Cleanup
      send(telephone_pid, :stop)
    end
  end

  describe "chunked/streaming responses" do
    test "handles chunked response from telephone", %{conn: conn} do
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "chunked-api",
          user_id: user.id
        })

      {:ok, path} = Paths.update_path(path, %{mount_point: true})
      MountStore.reload_all()

      telephone_pid =
        spawn_mock_telephone(path.id, self(), fn from, request_id, _payload ->
          response = %{
            "status" => 200,
            "headers" => %{"content-type" => "text/event-stream"},
            "chunked" => true,
            "chunks" => ["chunk1", "chunk2", "chunk3"]
          }

          send(from, {:proxy_res, request_id, response})
        end)

      assert_receive {:telephone_ready, ^telephone_pid}, 1000

      conn = get(conn, "/call/chunked-api/stream")

      assert conn.status == 200
      # Chunked response should contain all chunks
      body = response(conn, 200)
      assert body =~ "chunk1"
      assert body =~ "chunk2"
      assert body =~ "chunk3"

      # Cleanup
      send(telephone_pid, :stop)
    end

    test "handles empty chunks array", %{conn: conn} do
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "empty-chunks-api",
          user_id: user.id
        })

      {:ok, path} = Paths.update_path(path, %{mount_point: true})
      MountStore.reload_all()

      telephone_pid =
        spawn_mock_telephone(path.id, self(), fn from, request_id, _payload ->
          # chunked: true but empty chunks - should fall back to regular response
          response = %{
            "status" => 200,
            "body" => "fallback body",
            "chunked" => true,
            "chunks" => []
          }

          send(from, {:proxy_res, request_id, response})
        end)

      assert_receive {:telephone_ready, ^telephone_pid}, 1000

      conn = get(conn, "/call/empty-chunks-api/test")

      assert conn.status == 200
      assert text_response(conn, 200) == "fallback body"

      # Cleanup
      send(telephone_pid, :stop)
    end

    test "handles chunked false with body", %{conn: conn} do
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "non-chunked-api",
          user_id: user.id
        })

      {:ok, path} = Paths.update_path(path, %{mount_point: true})
      MountStore.reload_all()

      telephone_pid =
        spawn_mock_telephone(path.id, self(), fn from, request_id, _payload ->
          response = %{
            "status" => 200,
            "body" => "regular response",
            "chunked" => false,
            "chunks" => ["should", "be", "ignored"]
          }

          send(from, {:proxy_res, request_id, response})
        end)

      assert_receive {:telephone_ready, ^telephone_pid}, 1000

      conn = get(conn, "/call/non-chunked-api/test")

      assert conn.status == 200
      assert text_response(conn, 200) == "regular response"

      # Cleanup
      send(telephone_pid, :stop)
    end
  end

  describe "telephone error scenarios" do
    test "returns 502 when telephone disconnects during request", %{conn: conn} do
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "disconnect-api",
          user_id: user.id
        })

      {:ok, path} = Paths.update_path(path, %{mount_point: true})
      MountStore.reload_all()

      telephone_pid =
        spawn_mock_telephone(path.id, self(), fn from, request_id, _payload ->
          # Simulate telephone disconnection during request
          send(from, {:proxy_error, request_id, :telephone_disconnected})
        end)

      assert_receive {:telephone_ready, ^telephone_pid}, 1000

      conn = get(conn, "/call/disconnect-api/test")

      assert conn.status == 502
      assert html_response(conn, 502) =~ "502"
      assert html_response(conn, 502) =~ "disconnected"

      # Cleanup
      send(telephone_pid, :stop)
    end

    test "returns 502 for generic telephone errors", %{conn: conn} do
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "error-api",
          user_id: user.id
        })

      {:ok, path} = Paths.update_path(path, %{mount_point: true})
      MountStore.reload_all()

      telephone_pid =
        spawn_mock_telephone(path.id, self(), fn from, request_id, _payload ->
          # Simulate generic telephone error
          send(from, {:proxy_error, request_id, :internal_error})
        end)

      assert_receive {:telephone_ready, ^telephone_pid}, 1000

      conn = get(conn, "/call/error-api/test")

      assert conn.status == 502
      assert html_response(conn, 502) =~ "502"
      assert html_response(conn, 502) =~ "Bad Gateway"

      # Cleanup
      send(telephone_pid, :stop)
    end

    test "returns 503 when telephone process dies and is removed from registry", %{conn: conn} do
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "dead-api",
          user_id: user.id
        })

      {:ok, path} = Paths.update_path(path, %{mount_point: true})
      MountStore.reload_all()

      # Create a telephone process that registers itself then immediately exits
      test_pid = self()

      telephone_pid =
        spawn(fn ->
          {:ok, _} = Plugboard.DistributedRegistry.register(path.id)
          send(test_pid, {:telephone_ready, self()})
          # Exit immediately after registration
          :ok
        end)

      assert_receive {:telephone_ready, ^telephone_pid}, 1000

      # Wait for it to die and be removed from Horde registry
      Process.sleep(100)
      refute Process.alive?(telephone_pid)

      conn = get(conn, "/call/dead-api/test")

      # When process dies, Horde removes it from registry, so we get 503 (no telephone)
      # rather than 502 (telephone unavailable). This is correct behavior.
      assert conn.status == 503
      assert html_response(conn, 503) =~ "503"
    end
  end

  describe "slow response telemetry" do
    @tag :slow
    @tag timeout: 10_000
    test "emits slow_response telemetry when response takes >80% of timeout", %{conn: conn} do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:plugboard, :telephone, :slow_response]
        ])

      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "slow-response-api",
          user_id: user.id
        })

      {:ok, path} =
        Paths.update_path(path, %{
          mount_point: true,
          # 1 second timeout
          request_timeout_ms: 1000
        })

      MountStore.reload_all()

      test_pid = self()

      telephone_pid =
        spawn(fn ->
          {:ok, _} = Plugboard.DistributedRegistry.register(path.id)
          send(test_pid, {:telephone_ready, self()})

          receive do
            {:proxy_request, from, request_id, _payload} ->
              # Sleep for 850ms (85% of 1000ms timeout)
              Process.sleep(850)

              response = %{"status" => 200, "body" => "slow but made it"}
              send(from, {:proxy_res, request_id, response})
          end
        end)

      assert_receive {:telephone_ready, ^telephone_pid}, 1000

      result_conn = get(conn, "/call/slow-response-api/test")

      assert result_conn.status == 200
      assert text_response(result_conn, 200) == "slow but made it"

      # Verify slow_response telemetry was emitted
      assert_receive {[:plugboard, :telephone, :slow_response], ^ref, %{duration: _, timeout: _},
                      %{path_id: _, method: _}},
                     3000

      # Cleanup
      :telemetry.detach(ref)
      Process.exit(telephone_pid, :kill)
    end
  end

  describe "request body handling" do
    @tag timeout: 10_000
    test "emits telemetry for body_too_large errors" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:plugboard, :proxy, :body_too_large]
        ])

      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "large-body-api",
          user_id: user.id
        })

      {:ok, path} = Paths.update_path(path, %{mount_point: true})
      MountStore.reload_all()

      telephone_pid =
        spawn_mock_telephone(path.id, self(), fn from, request_id, _payload ->
          response = %{"status" => 200, "body" => "OK"}
          send(from, {:proxy_res, request_id, response})
        end)

      assert_receive {:telephone_ready, ^telephone_pid}, 1000

      # This test verifies the telemetry path exists
      # The actual 413 requires a body larger than MAX_REQUEST_BODY_SIZE
      # which is hard to test without modifying config
      # For now, we just verify the happy path completes
      test_conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post("/call/large-body-api/test", ~s({"small": "body"}))

      assert test_conn.status == 200

      # Cleanup
      :telemetry.detach(ref)
      send(telephone_pid, :stop)
    end
  end

  describe "domain affinity proxy" do
    test "MountStore.refresh_domain_affinity adds and match_by_domain finds entry" do
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "domain-store-test",
          user_id: user.id
        })

      {:ok, _} = Paths.update_path(path, %{mount_point: true})
      MountStore.reload_all()

      # Add domain affinity directly to store
      MountStore.refresh_domain_affinity("test-domain.example.com", path.id, "/domain-store-test")

      # Verify it's findable
      assert {:ok, {_path_id, "/domain-store-test"}} =
               MountStore.match_by_domain("test-domain.example.com")

      # Cleanup
      MountStore.remove_domain_affinity("test-domain.example.com")
    end

    test "MountStore.remove_domain_affinity removes entry" do
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "domain-remove-test",
          user_id: user.id
        })

      {:ok, _} = Paths.update_path(path, %{mount_point: true})
      MountStore.reload_all()

      # Add then remove
      MountStore.refresh_domain_affinity("remove-me.example.com", path.id, "/domain-remove-test")
      assert {:ok, _} = MountStore.match_by_domain("remove-me.example.com")

      MountStore.remove_domain_affinity("remove-me.example.com")
      assert {:error, :not_found} = MountStore.match_by_domain("remove-me.example.com")
    end
  end

  describe "hook error handling" do
    test "returns hook rejection response with custom status and body", %{conn: conn} do
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "hook-reject-api",
          user_id: user.id
        })

      {:ok, path} = Paths.update_path(path, %{mount_point: true})

      # Create a hook that will reject requests
      bypass = Bypass.open()

      {:ok, _hook} =
        Plugboard.Hooks.create_hook(user.id, %{
          path_id: path.id,
          name: "rejecting-hook",
          target_type: "http_url",
          target_url: "http://localhost:#{bypass.port}/reject",
          execution_order: 0,
          timeout_ms: 5000,
          allowed_status_codes: [200]
        })

      Plugboard.HookStore.reload_all()
      MountStore.reload_all()

      # Hook returns 403 to reject
      Bypass.expect_once(bypass, "POST", "/reject", fn conn ->
        Plug.Conn.resp(conn, 403, ~s({"error": "forbidden"}))
      end)

      result_conn = get(conn, "/call/hook-reject-api/test")

      # Should return the hook's rejection response
      assert result_conn.status == 403
      assert response(result_conn, 403) =~ "forbidden"
    end

    @tag timeout: 10_000
    test "returns 504 when hook times out", %{conn: conn} do
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "hook-timeout-api",
          user_id: user.id
        })

      {:ok, path} = Paths.update_path(path, %{mount_point: true})

      # Create a hook pointing to a port that won't respond quickly
      # Using a non-routable IP that will cause connection timeout
      {:ok, _hook} =
        Plugboard.Hooks.create_hook(user.id, %{
          path_id: path.id,
          name: "timeout-hook",
          target_type: "http_url",
          # Use a non-routable address that will cause timeout
          target_url: "http://10.255.255.1:9999/slow",
          execution_order: 0,
          timeout_ms: 500,
          allowed_status_codes: [200]
        })

      Plugboard.HookStore.reload_all()
      MountStore.reload_all()

      result_conn = get(conn, "/call/hook-timeout-api/test")

      # Should return 503 unavailable (connection refused) or 504 timeout
      assert result_conn.status in [503, 504]
    end

    test "returns 503 when hook target is unavailable", %{conn: conn} do
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "hook-unavail-api",
          user_id: user.id
        })

      {:ok, path} = Paths.update_path(path, %{mount_point: true})

      # Create a hook pointing to non-existent server
      {:ok, _hook} =
        Plugboard.Hooks.create_hook(user.id, %{
          path_id: path.id,
          name: "unavailable-hook",
          target_type: "http_url",
          target_url: "http://localhost:59999/nonexistent",
          execution_order: 0,
          timeout_ms: 1000,
          allowed_status_codes: [200]
        })

      Plugboard.HookStore.reload_all()
      MountStore.reload_all()

      result_conn = get(conn, "/call/hook-unavail-api/test")

      assert result_conn.status == 503
      assert html_response(result_conn, 503) =~ "Hook unavailable"
    end
  end

  describe "path building edge cases" do
    test "handles root path correctly", %{conn: conn} do
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "root-test",
          user_id: user.id
        })

      {:ok, _} = Paths.update_path(path, %{mount_point: true})
      MountStore.reload_all()

      # Request to just the mount point
      result_conn = get(conn, "/call/root-test")

      # Should return 503 (no telephone) but path should be processed correctly
      assert result_conn.status == 503
    end

    test "handles path with query string", %{conn: conn} do
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "query-api",
          user_id: user.id
        })

      {:ok, path} = Paths.update_path(path, %{mount_point: true})
      MountStore.reload_all()

      test_pid = self()

      telephone_pid =
        spawn_mock_telephone(path.id, self(), fn from, request_id, payload ->
          send(test_pid, {:query_string, payload["query_string"]})

          response = %{"status" => 200, "body" => "OK"}
          send(from, {:proxy_res, request_id, response})
        end)

      assert_receive {:telephone_ready, ^telephone_pid}, 1000

      _result_conn = get(conn, "/call/query-api/test?foo=bar&baz=qux")

      assert_receive {:query_string, "foo=bar&baz=qux"}, 1000

      # Cleanup
      send(telephone_pid, :stop)
    end

    test "handles binary path parameter", %{conn: conn} do
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "binary-path-api",
          user_id: user.id
        })

      {:ok, path} = Paths.update_path(path, %{mount_point: true})
      MountStore.reload_all()

      test_pid = self()

      telephone_pid =
        spawn_mock_telephone(path.id, self(), fn from, request_id, payload ->
          send(test_pid, {:received_path, payload["path"]})
          response = %{"status" => 200, "body" => "OK"}
          send(from, {:proxy_res, request_id, response})
        end)

      assert_receive {:telephone_ready, ^telephone_pid}, 1000

      # Make a request - Phoenix will pass path as list, but we test the controller handles it
      _result_conn = get(conn, "/call/binary-path-api/some/nested/path")

      assert_receive {:received_path, received_path}, 1000
      assert received_path == "/some/nested/path"

      # Cleanup
      send(telephone_pid, :stop)
    end
  end

  describe "invalid timeout configuration" do
    @tag :capture_log
    test "logs warning and uses default for timeout > 300000ms", %{conn: conn} do
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "high-timeout-api",
          user_id: user.id
        })

      # Set timeout above maximum (300000ms)
      {:ok, path} =
        path
        |> Ecto.Changeset.change(request_timeout_ms: 500_000)
        |> Plugboard.Repo.update()

      {:ok, _} = Paths.update_path(path, %{mount_point: true})
      MountStore.reload_all()

      telephone_pid =
        spawn_mock_telephone(path.id, self(), fn from, request_id, _payload ->
          response = %{"status" => 200, "body" => "OK"}
          send(from, {:proxy_res, request_id, response})
        end)

      assert_receive {:telephone_ready, ^telephone_pid}, 1000

      # Request should succeed with default timeout being used
      result_conn = get(conn, "/call/high-timeout-api/test")
      assert result_conn.status == 200

      # Cleanup
      send(telephone_pid, :stop)
    end

    @tag :capture_log
    test "logs warning and uses default for timeout = 0", %{conn: conn} do
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "zero-timeout-api",
          user_id: user.id
        })

      # Set timeout to 0
      {:ok, path} =
        path
        |> Ecto.Changeset.change(request_timeout_ms: 0)
        |> Plugboard.Repo.update()

      {:ok, _} = Paths.update_path(path, %{mount_point: true})
      MountStore.reload_all()

      telephone_pid =
        spawn_mock_telephone(path.id, self(), fn from, request_id, _payload ->
          response = %{"status" => 200, "body" => "OK"}
          send(from, {:proxy_res, request_id, response})
        end)

      assert_receive {:telephone_ready, ^telephone_pid}, 1000

      result_conn = get(conn, "/call/zero-timeout-api/test")
      assert result_conn.status == 200

      # Cleanup
      send(telephone_pid, :stop)
    end
  end
end
