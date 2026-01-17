defmodule Plugboard.RateLimiterTest do
  use ExUnit.Case, async: false

  alias Plugboard.RateLimiter

  @table :plugboard_rate_limit_counters

  setup do
    # Clean ETS table before each test
    :ets.delete_all_objects(@table)
    :ok
  end

  describe "check/2" do
    test "allows requests under limit" do
      # Default auth limit is 5
      assert :ok = RateLimiter.check(:auth, "test-ip-1")
      assert :ok = RateLimiter.check(:auth, "test-ip-1")
      assert :ok = RateLimiter.check(:auth, "test-ip-1")
      assert :ok = RateLimiter.check(:auth, "test-ip-1")
      assert :ok = RateLimiter.check(:auth, "test-ip-1")
    end

    test "denies requests over limit" do
      # Default auth limit is 5, so 6th request should be denied
      for _ <- 1..5, do: assert(:ok = RateLimiter.check(:auth, "test-ip-2"))

      assert {:error, :rate_limited} = RateLimiter.check(:auth, "test-ip-2")
    end

    test "different buckets are independent" do
      # Exhaust auth limit
      for _ <- 1..5, do: assert(:ok = RateLimiter.check(:auth, "test-ip-3"))
      assert {:error, :rate_limited} = RateLimiter.check(:auth, "test-ip-3")

      # API bucket should still allow requests
      assert :ok = RateLimiter.check(:api, "test-ip-3")
    end

    test "different keys are independent" do
      # Exhaust limit for one IP
      for _ <- 1..5, do: assert(:ok = RateLimiter.check(:auth, "ip-a"))
      assert {:error, :rate_limited} = RateLimiter.check(:auth, "ip-a")

      # Different IP should still be allowed
      assert :ok = RateLimiter.check(:auth, "ip-b")
    end

    test "respects api bucket limits" do
      # Default API limit is 100
      for _ <- 1..100, do: assert(:ok = RateLimiter.check(:api, "test-api-key"))

      assert {:error, :rate_limited} = RateLimiter.check(:api, "test-api-key")
    end

    test "respects proxy bucket limits" do
      # Default proxy limit is 10000 - test a subset for performance
      for _ <- 1..100, do: assert(:ok = RateLimiter.check(:proxy, "test-proxy-ip"))

      # Should still be under limit
      assert :ok = RateLimiter.check(:proxy, "test-proxy-ip")
    end
  end

  describe "check_with_count/2" do
    test "returns remaining count on success" do
      config = RateLimiter.get_bucket_config(:auth)
      limit = config.limit

      assert {:ok, remaining} = RateLimiter.check_with_count(:auth, "count-test-1")
      assert remaining == limit - 1
    end

    test "returns zero remaining on rate limit" do
      # Exhaust auth limit
      for _ <- 1..5, do: RateLimiter.check(:auth, "count-test-2")

      assert {:error, :rate_limited, 0} = RateLimiter.check_with_count(:auth, "count-test-2")
    end

    test "decrements remaining count correctly" do
      config = RateLimiter.get_bucket_config(:auth)
      limit = config.limit

      {:ok, r1} = RateLimiter.check_with_count(:auth, "count-test-3")
      {:ok, r2} = RateLimiter.check_with_count(:auth, "count-test-3")
      {:ok, r3} = RateLimiter.check_with_count(:auth, "count-test-3")

      assert r1 == limit - 1
      assert r2 == limit - 2
      assert r3 == limit - 3
    end
  end

  describe "reset/2" do
    test "resets rate limit for key" do
      # Exhaust limit
      for _ <- 1..5, do: RateLimiter.check(:auth, "reset-test-1")
      assert {:error, :rate_limited} = RateLimiter.check(:auth, "reset-test-1")

      # Reset
      assert :ok = RateLimiter.reset(:auth, "reset-test-1")

      # Should be allowed again
      assert :ok = RateLimiter.check(:auth, "reset-test-1")
    end

    test "only resets the specific key" do
      # Exhaust limit for two keys
      for _ <- 1..5, do: RateLimiter.check(:auth, "reset-a")
      for _ <- 1..5, do: RateLimiter.check(:auth, "reset-b")

      # Reset only one
      RateLimiter.reset(:auth, "reset-a")

      # Only reset-a should be allowed
      assert :ok = RateLimiter.check(:auth, "reset-a")
      assert {:error, :rate_limited} = RateLimiter.check(:auth, "reset-b")
    end
  end

  describe "get_bucket_config/1" do
    test "returns config for auth bucket" do
      config = RateLimiter.get_bucket_config(:auth)

      assert is_map(config)
      assert Map.has_key?(config, :limit)
      assert Map.has_key?(config, :window_ms)
      assert is_integer(config.limit)
      assert is_integer(config.window_ms)
    end

    test "returns config for api bucket" do
      config = RateLimiter.get_bucket_config(:api)

      assert config.limit == 100
      assert config.window_ms == 60_000
    end

    test "returns config for proxy bucket" do
      config = RateLimiter.get_bucket_config(:proxy)

      assert config.limit == 10_000
      assert config.window_ms == 60_000
    end

    test "returns default config for unknown bucket" do
      config = RateLimiter.get_bucket_config(:unknown)

      assert is_map(config)
      assert Map.has_key?(config, :limit)
      assert Map.has_key?(config, :window_ms)
    end
  end

  describe "concurrent requests" do
    test "handles concurrent requests safely" do
      key = "concurrent-test"

      # Spawn multiple processes making requests simultaneously
      tasks =
        for _ <- 1..10 do
          Task.async(fn ->
            RateLimiter.check(:auth, key)
          end)
        end

      results = Task.await_many(tasks)

      # Should have 5 :ok and 5 {:error, :rate_limited}
      ok_count = Enum.count(results, &(&1 == :ok))
      error_count = Enum.count(results, &match?({:error, :rate_limited}, &1))

      assert ok_count == 5
      assert error_count == 5
    end
  end

  describe "window expiration" do
    test "resets counter after window expires" do
      # Use a very short window for testing (we can't easily test with real time)
      # This test verifies the mechanism works by checking the ETS entry directly
      key = "auth:window-test"

      # Make a request
      RateLimiter.check(:auth, "window-test")

      # Verify entry exists
      [{^key, count, timestamp}] = :ets.lookup(@table, key)
      assert count == 1
      assert is_integer(timestamp)

      # Simulate expired entry by inserting with old timestamp
      old_timestamp = System.system_time(:millisecond) - 120_000
      :ets.insert(@table, {key, 5, old_timestamp})

      # Next request should reset the counter (window expired)
      assert :ok = RateLimiter.check(:auth, "window-test")

      # Verify counter was reset
      [{^key, new_count, new_timestamp}] = :ets.lookup(@table, key)
      assert new_count == 1
      assert new_timestamp > old_timestamp
    end
  end
end
