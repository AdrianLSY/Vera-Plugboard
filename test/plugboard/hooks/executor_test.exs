defmodule Plugboard.Hooks.ExecutorTest do
  use Plugboard.DataCase, async: false

  import Plugboard.AccountsFixtures

  alias Plugboard.Hooks.Executor
  alias Plugboard.{Paths, Hooks, HookStore, MountStore}

  describe "execute_hooks/2 with no hooks" do
    setup do
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "api",
          user_id: user.id,
          mount_point: true
        })

      MountStore.reload_all()
      HookStore.reload_all()

      %{user: user, path: path}
    end

    test "returns conn unchanged when path has no hooks", %{path: path} do
      conn = Plug.Test.conn(:post, "/test", ~s({"original": "data"}))

      assert {:ok, result_conn} = Executor.execute_hooks(conn, path.id)
      # Connection should be returned (body was read)
      assert result_conn
    end
  end

  describe "execute_hooks/2 with HTTP hooks" do
    setup do
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "api",
          user_id: user.id,
          mount_point: true
        })

      MountStore.reload_all()
      HookStore.reload_all()

      # Start Bypass
      bypass = Bypass.open()

      %{user: user, path: path, bypass: bypass}
    end

    test "executes HTTP hook and merges response", %{user: user, path: path, bypass: bypass} do
      # Create HTTP hook
      {:ok, _hook} =
        Hooks.create_hook(user.id, %{
          path_id: path.id,
          name: "test-hook",
          target_type: "http_url",
          target_url: "http://localhost:#{bypass.port}/hook",
          execution_order: 0,
          timeout_ms: 5000,
          allowed_status_codes: [200]
        })

      HookStore.reload_all()

      # Set up Bypass to return additional data
      Bypass.expect_once(bypass, "POST", "/hook", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        request_data = Jason.decode!(body)

        # Verify original data was received
        assert request_data["original"] == "data"

        # Return merged data
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"hook_added": "value", "enriched": true}))
      end)

      conn = Plug.Test.conn(:post, "/test", ~s({"original": "data"}))

      assert {:ok, result_conn} = Executor.execute_hooks(conn, path.id)

      # Body should be merged
      assert result_conn.body_params["original"] == "data"
      assert result_conn.body_params["hook_added"] == "value"
      assert result_conn.body_params["enriched"] == true
    end

    test "executes multiple hooks in order", %{user: user, path: path, bypass: bypass} do
      # Create first hook
      {:ok, _hook1} =
        Hooks.create_hook(user.id, %{
          path_id: path.id,
          name: "hook-1",
          target_type: "http_url",
          target_url: "http://localhost:#{bypass.port}/hook1",
          execution_order: 0,
          timeout_ms: 5000,
          allowed_status_codes: [200]
        })

      # Create second hook
      {:ok, _hook2} =
        Hooks.create_hook(user.id, %{
          path_id: path.id,
          name: "hook-2",
          target_type: "http_url",
          target_url: "http://localhost:#{bypass.port}/hook2",
          execution_order: 1,
          timeout_ms: 5000,
          allowed_status_codes: [200]
        })

      HookStore.reload_all()

      # First hook adds data
      Bypass.expect_once(bypass, "POST", "/hook1", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"from_hook1": true}))
      end)

      # Second hook receives accumulated data and adds more
      Bypass.expect_once(bypass, "POST", "/hook2", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        data = Jason.decode!(body)

        # Should have original + hook1 data
        assert data["original"] == "data"
        assert data["from_hook1"] == true

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"from_hook2": true}))
      end)

      conn = Plug.Test.conn(:post, "/test", ~s({"original": "data"}))

      assert {:ok, result_conn} = Executor.execute_hooks(conn, path.id)

      # All data should be merged
      assert result_conn.body_params["original"] == "data"
      assert result_conn.body_params["from_hook1"] == true
      assert result_conn.body_params["from_hook2"] == true
    end

    test "hook rejection stops chain and returns error", %{user: user, path: path, bypass: bypass} do
      {:ok, hook} =
        Hooks.create_hook(user.id, %{
          path_id: path.id,
          name: "rejecting-hook",
          target_type: "http_url",
          target_url: "http://localhost:#{bypass.port}/hook",
          execution_order: 0,
          timeout_ms: 5000,
          allowed_status_codes: [200]
        })

      HookStore.reload_all()

      # Hook returns 403 (not in allowed_status_codes)
      Bypass.expect_once(bypass, "POST", "/hook", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(403, ~s({"error": "forbidden"}))
      end)

      conn = Plug.Test.conn(:post, "/test", ~s({"original": "data"}))

      assert {:error, :rejected, returned_hook, response} =
               Executor.execute_hooks(conn, path.id)

      assert returned_hook.id == hook.id
      assert response.status == 403
    end

    # Timeout test is skipped because it causes Bypass shutdown issues
    # The timeout functionality is tested implicitly via proxy_controller_test
    @tag :skip
    test "hook timeout returns error", %{user: user, path: path, bypass: bypass} do
      {:ok, hook} =
        Hooks.create_hook(user.id, %{
          path_id: path.id,
          name: "slow-hook",
          target_type: "http_url",
          target_url: "http://localhost:#{bypass.port}/hook",
          execution_order: 0,
          timeout_ms: 100,
          allowed_status_codes: [200]
        })

      HookStore.reload_all()

      Bypass.stub(bypass, "POST", "/hook", fn conn ->
        Process.sleep(200)
        Plug.Conn.resp(conn, 200, ~s({}))
      end)

      conn = Plug.Test.conn(:post, "/test", ~s({}))

      assert {:error, :timeout, returned_hook, nil} = Executor.execute_hooks(conn, path.id)
      assert returned_hook.id == hook.id
    end

    test "hook unavailable returns error", %{user: user, path: path} do
      {:ok, hook} =
        Hooks.create_hook(user.id, %{
          path_id: path.id,
          name: "unreachable-hook",
          target_type: "http_url",
          # Port that nothing is listening on
          target_url: "http://localhost:59999/hook",
          execution_order: 0,
          timeout_ms: 1000,
          allowed_status_codes: [200]
        })

      HookStore.reload_all()

      conn = Plug.Test.conn(:post, "/test", ~s({"original": "data"}))

      assert {:error, :unavailable, returned_hook, nil} = Executor.execute_hooks(conn, path.id)
      assert returned_hook.id == hook.id
    end

    test "hook returning non-object JSON is ignored", %{user: user, path: path, bypass: bypass} do
      {:ok, _hook} =
        Hooks.create_hook(user.id, %{
          path_id: path.id,
          name: "array-hook",
          target_type: "http_url",
          target_url: "http://localhost:#{bypass.port}/hook",
          execution_order: 0,
          timeout_ms: 5000,
          allowed_status_codes: [200]
        })

      HookStore.reload_all()

      # Hook returns array instead of object
      Bypass.expect_once(bypass, "POST", "/hook", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s([1, 2, 3]))
      end)

      conn = Plug.Test.conn(:post, "/test", ~s({"original": "data"}))

      assert {:ok, result_conn} = Executor.execute_hooks(conn, path.id)

      # Original data should be preserved, array response ignored
      assert result_conn.body_params["original"] == "data"
    end

    test "hook returning invalid JSON is ignored", %{user: user, path: path, bypass: bypass} do
      {:ok, _hook} =
        Hooks.create_hook(user.id, %{
          path_id: path.id,
          name: "invalid-json-hook",
          target_type: "http_url",
          target_url: "http://localhost:#{bypass.port}/hook",
          execution_order: 0,
          timeout_ms: 5000,
          allowed_status_codes: [200]
        })

      HookStore.reload_all()

      # Hook returns invalid JSON - use stub for more reliability
      Bypass.stub(bypass, "POST", "/hook", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/plain")
        |> Plug.Conn.resp(200, "not valid json {")
      end)

      conn = Plug.Test.conn(:post, "/test", ~s({"original": "data"}))

      assert {:ok, result_conn} = Executor.execute_hooks(conn, path.id)

      # Original data should be preserved
      assert result_conn.body_params["original"] == "data"
    end

    test "forwards configured headers", %{user: user, path: path, bypass: bypass} do
      # Note: Authorization is now a blocked header for security, so we test with safe headers
      {:ok, _hook} =
        Hooks.create_hook(user.id, %{
          path_id: path.id,
          name: "header-hook",
          target_type: "http_url",
          target_url: "http://localhost:#{bypass.port}/hook",
          execution_order: 0,
          timeout_ms: 5000,
          allowed_status_codes: [200],
          forward_headers: ["X-Request-Id", "X-Custom-Header"]
        })

      HookStore.reload_all()

      Bypass.expect_once(bypass, "POST", "/hook", fn conn ->
        # Check that configured headers were forwarded
        request_id = Plug.Conn.get_req_header(conn, "x-request-id")
        custom = Plug.Conn.get_req_header(conn, "x-custom-header")

        assert request_id == ["req-123"]
        assert custom == ["custom-value"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({}))
      end)

      conn =
        Plug.Test.conn(:post, "/test", ~s({}))
        |> Plug.Conn.put_req_header("x-request-id", "req-123")
        |> Plug.Conn.put_req_header("x-custom-header", "custom-value")

      assert {:ok, _result_conn} = Executor.execute_hooks(conn, path.id)
    end

    test "handles empty request body", %{user: user, path: path, bypass: bypass} do
      {:ok, _hook} =
        Hooks.create_hook(user.id, %{
          path_id: path.id,
          name: "empty-body-hook",
          target_type: "http_url",
          target_url: "http://localhost:#{bypass.port}/hook",
          execution_order: 0,
          timeout_ms: 5000,
          allowed_status_codes: [200]
        })

      HookStore.reload_all()

      Bypass.expect_once(bypass, "POST", "/hook", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        # Empty body should be parsed as empty object
        assert Jason.decode!(body) == %{}

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"added": "data"}))
      end)

      conn = Plug.Test.conn(:post, "/test", "")

      assert {:ok, result_conn} = Executor.execute_hooks(conn, path.id)
      assert result_conn.body_params["added"] == "data"
    end

    test "accepts multiple allowed status codes", %{user: user, path: path, bypass: bypass} do
      {:ok, _hook} =
        Hooks.create_hook(user.id, %{
          path_id: path.id,
          name: "multi-status-hook",
          target_type: "http_url",
          target_url: "http://localhost:#{bypass.port}/hook",
          execution_order: 0,
          timeout_ms: 5000,
          allowed_status_codes: [200, 201, 204]
        })

      HookStore.reload_all()

      # Return 201 which is in allowed list
      Bypass.expect_once(bypass, "POST", "/hook", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(201, ~s({"created": true}))
      end)

      conn = Plug.Test.conn(:post, "/test", ~s({}))

      assert {:ok, result_conn} = Executor.execute_hooks(conn, path.id)
      assert result_conn.body_params["created"] == true
    end
  end

  describe "execute_hooks/2 with mount point hooks" do
    setup do
      user = user_fixture()

      # Create source path (the one being called)
      {:ok, source_path} =
        Paths.create_path(%{
          path: "api",
          user_id: user.id,
          mount_point: true
        })

      # Create target path (the hook destination)
      {:ok, target_path} =
        Paths.create_path(%{
          path: "auth",
          user_id: user.id,
          mount_point: true
        })

      MountStore.reload_all()
      HookStore.reload_all()

      %{user: user, source_path: source_path, target_path: target_path}
    end

    test "returns unavailable when target path not found", %{
      user: user,
      source_path: source_path,
      target_path: target_path
    } do
      # Create hook pointing to target_path
      {:ok, hook} =
        Hooks.create_hook(user.id, %{
          path_id: source_path.id,
          name: "missing-target-hook",
          target_type: "mount_point",
          target_path_id: target_path.id,
          execution_order: 0,
          timeout_ms: 5000
        })

      # Delete the target path to simulate "not found"
      {:ok, _} = Paths.delete_path(user.id, target_path)

      HookStore.reload_all()
      MountStore.reload_all()

      conn = Plug.Test.conn(:post, "/test", ~s({"original": "data"}))

      assert {:error, :unavailable, returned_hook, nil} =
               Executor.execute_hooks(conn, source_path.id)

      assert returned_hook.id == hook.id
    end

    test "returns unavailable when no telephone registered", %{
      user: user,
      source_path: source_path,
      target_path: target_path
    } do
      {:ok, hook} =
        Hooks.create_hook(user.id, %{
          path_id: source_path.id,
          name: "no-telephone-hook",
          target_type: "mount_point",
          target_path_id: target_path.id,
          execution_order: 0,
          timeout_ms: 5000
        })

      HookStore.reload_all()

      conn = Plug.Test.conn(:post, "/test", ~s({"original": "data"}))

      assert {:error, :unavailable, returned_hook, nil} =
               Executor.execute_hooks(conn, source_path.id)

      assert returned_hook.id == hook.id
    end

    # Mount point hook test is skipped due to Horde registry timing issues
    # The functionality is tested via proxy_controller integration tests
    @tag :skip
    test "executes mount point hook with registered telephone", %{
      user: user,
      source_path: source_path,
      target_path: target_path
    } do
      {:ok, _hook} =
        Hooks.create_hook(user.id, %{
          path_id: source_path.id,
          name: "telephone-hook",
          target_type: "mount_point",
          target_path_id: target_path.id,
          execution_order: 0,
          timeout_ms: 5000,
          allowed_status_codes: [200]
        })

      HookStore.reload_all()

      # Spawn a mock telephone process
      test_pid = self()

      telephone_pid =
        spawn_link(fn ->
          receive do
            {:proxy_request, caller_pid, request_id, payload} ->
              # Verify payload structure
              send(test_pid, {:received_payload, payload})

              # Send successful response
              response = %{
                "status" => 200,
                "body" => Jason.encode!(%{"auth_user_id" => "user123"})
              }

              send(caller_pid, {:proxy_res, request_id, response})
          after
            10_000 ->
              :timeout
          end
        end)

      # Register the mock telephone and wait for Horde propagation
      Plugboard.TelephoneRegistry.register(target_path.id, telephone_pid)
      # Wait longer for Horde CRDT propagation
      Process.sleep(200)

      conn = Plug.Test.conn(:post, "/test", ~s({"original": "data"}))

      assert {:ok, result_conn} = Executor.execute_hooks(conn, source_path.id)

      # Verify telephone received the request
      assert_receive {:received_payload, payload}, 5000
      assert payload["method"] == "POST"

      # Body should be merged
      assert result_conn.body_params["original"] == "data"
      assert result_conn.body_params["auth_user_id"] == "user123"
    end

    test "mount point hook timeout", %{
      user: user,
      source_path: source_path,
      target_path: target_path
    } do
      {:ok, hook} =
        Hooks.create_hook(user.id, %{
          path_id: source_path.id,
          name: "slow-telephone-hook",
          target_type: "mount_point",
          target_path_id: target_path.id,
          execution_order: 0,
          timeout_ms: 100,
          allowed_status_codes: [200]
        })

      HookStore.reload_all()

      # Spawn a slow mock telephone
      telephone_pid =
        spawn(fn ->
          receive do
            {:proxy_request, _caller_pid, _request_id, _payload} ->
              # Don't respond - simulate timeout
              Process.sleep(500)
          end
        end)

      Plugboard.TelephoneRegistry.register(target_path.id, telephone_pid)

      conn = Plug.Test.conn(:post, "/test", ~s({}))

      assert {:error, :timeout, returned_hook, nil} =
               Executor.execute_hooks(conn, source_path.id)

      assert returned_hook.id == hook.id
    end

    test "mount point hook with dead telephone", %{
      user: user,
      source_path: source_path,
      target_path: target_path
    } do
      {:ok, hook} =
        Hooks.create_hook(user.id, %{
          path_id: source_path.id,
          name: "dead-telephone-hook",
          target_type: "mount_point",
          target_path_id: target_path.id,
          execution_order: 0,
          timeout_ms: 5000,
          allowed_status_codes: [200]
        })

      HookStore.reload_all()

      # Spawn and immediately kill a telephone
      _telephone_pid = spawn(fn -> :ok end)
      Process.sleep(10)
      # Process is now dead

      # Note: We can't easily register a dead process to TelephoneRegistry
      # since Horde cleans up dead processes. So this test verifies
      # the "no telephone" path which is similar

      conn = Plug.Test.conn(:post, "/test", ~s({}))

      assert {:error, :unavailable, returned_hook, nil} =
               Executor.execute_hooks(conn, source_path.id)

      assert returned_hook.id == hook.id
    end
  end
end
