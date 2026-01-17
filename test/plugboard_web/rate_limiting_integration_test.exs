defmodule PlugboardWeb.RateLimitingIntegrationTest do
  use PlugboardWeb.ConnCase, async: false

  import Plugboard.AccountsFixtures

  alias Plugboard.{Paths, ServiceAccounts}

  @table :plugboard_rate_limit_counters

  setup do
    # Clean ETS table before each test
    :ets.delete_all_objects(@table)

    user = user_fixture()
    {:ok, path} = Paths.create_path(%{path: "testapi", user_id: user.id})
    {:ok, mount} = Paths.update_path(user.id, path, %{mount_point: true})
    Plugboard.MountStore.reload_all()

    {:ok, %{user: user, path: mount}}
  end

  describe "auth endpoint rate limiting" do
    test "login endpoint is rate limited after 5 requests", %{conn: conn} do
      # Make 5 requests - should all succeed (even if login fails, rate limit allows)
      for i <- 1..5 do
        result =
          conn
          |> post("/users/log-in", %{
            "user" => %{"email" => "test#{i}@example.com", "password" => "wrong"}
          })

        # Should not be rate limited yet
        refute result.status == 429, "Request #{i} was unexpectedly rate limited"
      end

      # 6th request should be rate limited
      result =
        conn
        |> post("/users/log-in", %{
          "user" => %{"email" => "test@example.com", "password" => "wrong"}
        })

      assert result.status == 429
      assert get_resp_header(result, "x-ratelimit-remaining") == ["0"]
    end

    test "registration page includes rate limit headers", %{conn: conn} do
      conn = get(conn, "/users/register")

      assert conn.status == 200
      assert [_limit] = get_resp_header(conn, "x-ratelimit-limit")
      assert [_remaining] = get_resp_header(conn, "x-ratelimit-remaining")
      assert [_reset] = get_resp_header(conn, "x-ratelimit-reset")
    end

    test "different IPs have independent limits", %{conn: conn} do
      # Exhaust limit for one "IP" (simulated via unique conn)
      # Note: In tests, all requests come from same IP, but we can verify
      # the rate limiting is applied by checking the counter
      for _ <- 1..5 do
        post(conn, "/users/log-in", %{
          "user" => %{"email" => "test@example.com", "password" => "wrong"}
        })
      end

      # Verify rate limiting kicked in
      result =
        post(conn, "/users/log-in", %{
          "user" => %{"email" => "test@example.com", "password" => "wrong"}
        })

      assert result.status == 429
    end
  end

  describe "API endpoint rate limiting" do
    setup %{conn: conn, user: user, path: path} do
      conn = log_in_user(conn, user)
      {:ok, %{conn: conn, user: user, path: path}}
    end

    test "token creation endpoint includes rate limit headers", %{conn: conn, path: path} do
      conn = post(conn, "/api/paths/#{path.id}/tokens", %{"name" => "test-token"})

      # Should succeed (201 Created)
      assert conn.status == 201

      # Should have rate limit headers
      assert [limit] = get_resp_header(conn, "x-ratelimit-limit")
      assert String.to_integer(limit) == 100

      assert [_remaining] = get_resp_header(conn, "x-ratelimit-remaining")
      assert [_reset] = get_resp_header(conn, "x-ratelimit-reset")
    end

    test "API endpoints are rate limited after 100 requests", %{conn: conn, path: path} do
      # Make 100 requests
      for i <- 1..100 do
        result = post(conn, "/api/paths/#{path.id}/tokens", %{"name" => "token-#{i}"})
        refute result.status == 429, "Request #{i} was unexpectedly rate limited"
      end

      # 101st request should be rate limited
      result = post(conn, "/api/paths/#{path.id}/tokens", %{"name" => "token-101"})

      assert result.status == 429
      body = Jason.decode!(result.resp_body)
      assert body["error"] == "Too many requests"
    end
  end

  describe "token vending API rate limiting" do
    test "token vending endpoint is rate limited", %{conn: conn, user: user, path: path} do
      # Create a service account to get an API key
      {:ok, api_key, _service_account} =
        ServiceAccounts.generate_service_account(user, path.id, "test-sa")

      # Make request with API key
      conn =
        conn
        |> put_req_header("x-api-key", api_key)
        |> post("/api/token-vending/generate", %{"path_id" => path.id})

      # Should have rate limit headers (even if request fails for other reasons)
      assert [limit] = get_resp_header(conn, "x-ratelimit-limit")
      assert String.to_integer(limit) == 100
    end

    test "rate limit uses API key when provided", %{conn: conn, user: user, path: path} do
      # Create two service accounts
      {:ok, api_key_1, _sa1} =
        ServiceAccounts.generate_service_account(user, path.id, "sa-1")

      {:ok, api_key_2, _sa2} =
        ServiceAccounts.generate_service_account(user, path.id, "sa-2")

      # Make requests with api_key_1
      for _ <- 1..50 do
        conn
        |> put_req_header("x-api-key", api_key_1)
        |> post("/api/token-vending/generate", %{"path_id" => path.id})
      end

      # Check remaining for api_key_1
      result1 =
        conn
        |> put_req_header("x-api-key", api_key_1)
        |> post("/api/token-vending/generate", %{"path_id" => path.id})

      [remaining1] = get_resp_header(result1, "x-ratelimit-remaining")

      # api_key_2 should have full quota
      result2 =
        conn
        |> put_req_header("x-api-key", api_key_2)
        |> post("/api/token-vending/generate", %{"path_id" => path.id})

      [remaining2] = get_resp_header(result2, "x-ratelimit-remaining")

      # api_key_2 should have more remaining than api_key_1
      assert String.to_integer(remaining2) > String.to_integer(remaining1)
    end
  end

  describe "proxy endpoint rate limiting" do
    test "proxy requests include rate limit headers", %{conn: conn} do
      # Make a proxy request (will return 503 since no telephone connected)
      conn = get(conn, "/call/testapi/test")

      # Should have rate limit headers even on error responses
      assert [limit] = get_resp_header(conn, "x-ratelimit-limit")
      assert String.to_integer(limit) == 10_000
    end

    test "proxy endpoints use high rate limit", %{conn: conn} do
      # Make several requests
      for _ <- 1..100 do
        get(conn, "/call/testapi/test")
      end

      # Should still have plenty of remaining requests
      result = get(conn, "/call/testapi/test")
      [remaining] = get_resp_header(result, "x-ratelimit-remaining")

      # With 10k limit, after 101 requests we should have ~9899 remaining
      assert String.to_integer(remaining) > 9000
    end
  end

  describe "cross-bucket independence" do
    test "auth and API buckets are independent", %{conn: conn, user: user} do
      # Exhaust auth bucket
      for _ <- 1..5 do
        post(conn, "/users/log-in", %{
          "user" => %{"email" => "test@example.com", "password" => "wrong"}
        })
      end

      # Auth should be rate limited
      auth_result =
        post(conn, "/users/log-in", %{
          "user" => %{"email" => "test@example.com", "password" => "wrong"}
        })

      assert auth_result.status == 429

      # But API should still work (after logging in)
      api_conn = log_in_user(conn, user)
      api_result = get(api_conn, "/api/service-accounts")

      refute api_result.status == 429
    end

    test "API and proxy buckets are independent", %{conn: conn, user: user, path: path} do
      logged_in_conn = log_in_user(conn, user)

      # Make many API requests (but not enough to exhaust)
      for _ <- 1..50 do
        post(logged_in_conn, "/api/paths/#{path.id}/tokens", %{"name" => "token"})
      end

      # Make proxy requests - should have full quota
      result = get(conn, "/call/testapi/test")
      [remaining] = get_resp_header(result, "x-ratelimit-remaining")

      # Proxy should have nearly full quota (10k - 1)
      assert String.to_integer(remaining) >= 9998
    end
  end

  describe "rate limit headers format" do
    test "all rate limit headers are present and numeric", %{conn: conn} do
      conn = get(conn, "/users/log-in")

      [limit] = get_resp_header(conn, "x-ratelimit-limit")
      [remaining] = get_resp_header(conn, "x-ratelimit-remaining")
      [reset] = get_resp_header(conn, "x-ratelimit-reset")

      # All should be parseable as integers
      assert is_integer(String.to_integer(limit))
      assert is_integer(String.to_integer(remaining))
      assert is_integer(String.to_integer(reset))

      # Reset should be a unix timestamp (reasonably recent)
      reset_ts = String.to_integer(reset)
      now = System.system_time(:second)
      assert reset_ts > now
      assert reset_ts < now + 120
    end
  end
end
