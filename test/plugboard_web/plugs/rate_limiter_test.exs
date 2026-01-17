defmodule PlugboardWeb.Plugs.RateLimiterTest do
  use PlugboardWeb.ConnCase, async: false

  alias PlugboardWeb.Plugs.RateLimiter

  @table :plugboard_rate_limit_counters

  setup do
    # Clean ETS table before each test
    :ets.delete_all_objects(@table)
    :ok
  end

  describe "rate limiting by IP" do
    test "allows requests under limit", %{conn: conn} do
      conn =
        conn
        |> Map.put(:remote_ip, {192, 168, 1, 100})
        |> RateLimiter.call(bucket: :auth, by: :ip)

      refute conn.halted
      assert get_resp_header(conn, "x-ratelimit-remaining") != []
    end

    test "returns 429 when limit exceeded", %{conn: conn} do
      ip = {192, 168, 1, 101}

      # Exhaust auth limit (5 requests)
      for _ <- 1..5 do
        conn
        |> Map.put(:remote_ip, ip)
        |> RateLimiter.call(bucket: :auth, by: :ip)
      end

      # 6th request should be rate limited
      result =
        conn
        |> Map.put(:remote_ip, ip)
        |> RateLimiter.call(bucket: :auth, by: :ip)

      assert result.halted
      assert result.status == 429
      assert get_resp_header(result, "x-ratelimit-remaining") == ["0"]
    end

    test "includes all rate limit headers on success", %{conn: conn} do
      conn =
        conn
        |> Map.put(:remote_ip, {192, 168, 1, 102})
        |> RateLimiter.call(bucket: :auth, by: :ip)

      assert [_limit] = get_resp_header(conn, "x-ratelimit-limit")
      assert [_remaining] = get_resp_header(conn, "x-ratelimit-remaining")
      assert [_reset] = get_resp_header(conn, "x-ratelimit-reset")
    end

    test "includes retry-after header on 429", %{conn: conn} do
      ip = {192, 168, 1, 103}

      # Exhaust limit
      for _ <- 1..5 do
        conn
        |> Map.put(:remote_ip, ip)
        |> RateLimiter.call(bucket: :auth, by: :ip)
      end

      result =
        conn
        |> Map.put(:remote_ip, ip)
        |> RateLimiter.call(bucket: :auth, by: :ip)

      assert [retry_after] = get_resp_header(result, "retry-after")
      assert String.to_integer(retry_after) > 0
    end

    test "returns correct JSON error body on 429", %{conn: conn} do
      ip = {192, 168, 1, 104}

      # Exhaust limit
      for _ <- 1..5 do
        conn
        |> Map.put(:remote_ip, ip)
        |> RateLimiter.call(bucket: :auth, by: :ip)
      end

      result =
        conn
        |> Map.put(:remote_ip, ip)
        |> RateLimiter.call(bucket: :auth, by: :ip)

      body = Jason.decode!(result.resp_body)
      assert body["error"] == "Too many requests"
      assert is_integer(body["retry_after"])
    end
  end

  describe "rate limiting by API key" do
    test "uses X-API-Key header when present", %{conn: conn} do
      api_key = "test-api-key-#{System.unique_integer()}"

      conn =
        conn
        |> put_req_header("x-api-key", api_key)
        |> RateLimiter.call(bucket: :api, by: :api_key)

      refute conn.halted

      # Check that the key was used (make requests with same API key)
      for _ <- 1..99 do
        conn
        |> put_req_header("x-api-key", api_key)
        |> RateLimiter.call(bucket: :api, by: :api_key)
      end

      # 101st request should be rate limited
      result =
        conn
        |> put_req_header("x-api-key", api_key)
        |> RateLimiter.call(bucket: :api, by: :api_key)

      assert result.halted
      assert result.status == 429
    end

    test "falls back to IP when header missing", %{conn: conn} do
      ip = {10, 0, 0, 1}

      # Make request without API key header
      conn =
        conn
        |> Map.put(:remote_ip, ip)
        |> RateLimiter.call(bucket: :api, by: :api_key)

      refute conn.halted

      # Verify it's using IP by exhausting with another request set
      # (this just verifies the request went through)
      assert get_resp_header(conn, "x-ratelimit-remaining") != []
    end

    test "different API keys have independent limits", %{conn: conn} do
      api_key_1 = "api-key-1-#{System.unique_integer()}"
      api_key_2 = "api-key-2-#{System.unique_integer()}"

      # Exhaust limit for api_key_1 (100 requests for API bucket)
      for _ <- 1..100 do
        conn
        |> put_req_header("x-api-key", api_key_1)
        |> RateLimiter.call(bucket: :api, by: :api_key)
      end

      # api_key_1 should be rate limited
      result1 =
        conn
        |> put_req_header("x-api-key", api_key_1)
        |> RateLimiter.call(bucket: :api, by: :api_key)

      assert result1.halted
      assert result1.status == 429

      # api_key_2 should still work
      result2 =
        conn
        |> put_req_header("x-api-key", api_key_2)
        |> RateLimiter.call(bucket: :api, by: :api_key)

      refute result2.halted
    end
  end

  describe "rate limiting by user ID" do
    test "uses current_scope.user.id when available", %{conn: conn} do
      user_id = Ecto.UUID.generate()

      conn =
        conn
        |> assign(:current_scope, %{user: %{id: user_id}})
        |> RateLimiter.call(bucket: :auth, by: :user_id)

      refute conn.halted
    end

    test "falls back to IP for unauthenticated users", %{conn: conn} do
      ip = {172, 16, 0, 1}

      conn =
        conn
        |> Map.put(:remote_ip, ip)
        |> RateLimiter.call(bucket: :auth, by: :user_id)

      refute conn.halted
      assert get_resp_header(conn, "x-ratelimit-remaining") != []
    end
  end

  describe "bucket types" do
    test "auth bucket uses correct limits", %{conn: conn} do
      ip = {192, 168, 2, 1}

      conn =
        conn
        |> Map.put(:remote_ip, ip)
        |> RateLimiter.call(bucket: :auth, by: :ip)

      [limit] = get_resp_header(conn, "x-ratelimit-limit")
      assert String.to_integer(limit) == 5
    end

    test "api bucket uses correct limits", %{conn: conn} do
      conn =
        conn
        |> Map.put(:remote_ip, {192, 168, 2, 2})
        |> RateLimiter.call(bucket: :api, by: :ip)

      [limit] = get_resp_header(conn, "x-ratelimit-limit")
      assert String.to_integer(limit) == 100
    end

    test "proxy bucket uses correct limits", %{conn: conn} do
      conn =
        conn
        |> Map.put(:remote_ip, {192, 168, 2, 3})
        |> RateLimiter.call(bucket: :proxy, by: :ip)

      [limit] = get_resp_header(conn, "x-ratelimit-limit")
      assert String.to_integer(limit) == 10_000
    end
  end

  describe "x-ratelimit-reset header" do
    test "returns a future unix timestamp", %{conn: conn} do
      now = System.system_time(:second)

      conn =
        conn
        |> Map.put(:remote_ip, {192, 168, 3, 1})
        |> RateLimiter.call(bucket: :auth, by: :ip)

      [reset] = get_resp_header(conn, "x-ratelimit-reset")
      reset_timestamp = String.to_integer(reset)

      # Reset should be in the future (now + window)
      assert reset_timestamp > now
      # But not too far in the future (within 2 minutes)
      assert reset_timestamp < now + 120
    end
  end
end
