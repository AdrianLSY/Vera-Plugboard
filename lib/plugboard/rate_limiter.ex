defmodule Plugboard.RateLimiter do
  @moduledoc """
  ETS-based rate limiting infrastructure.

  Provides rate limiting for:
  - Authentication endpoints (login, registration) - 5 requests/minute
  - API endpoints (token vending, etc.) - 100 requests/minute
  - Proxy requests per path - 10,000 requests/minute

  ## Configuration

  Configure via environment variables:

      RATE_LIMIT_AUTH_LIMIT=5           # Auth requests per window (default: 5)
      RATE_LIMIT_AUTH_WINDOW_MS=60000   # Auth window in ms (default: 60000)
      RATE_LIMIT_API_LIMIT=100          # API requests per window (default: 100)
      RATE_LIMIT_API_WINDOW_MS=60000    # API window in ms (default: 60000)
      RATE_LIMIT_PROXY_LIMIT=10000      # Proxy requests per window (default: 10000)
      RATE_LIMIT_PROXY_WINDOW_MS=60000  # Proxy window in ms (default: 60000)

  Or in `config/runtime.exs`:

      config :plugboard, Plugboard.RateLimiter,
        auth_limit: 5,
        auth_window_ms: 60_000,
        api_limit: 100,
        api_window_ms: 60_000,
        proxy_limit: 10_000,
        proxy_window_ms: 60_000

  ## Usage

      case RateLimiter.check(:auth, client_ip) do
        :ok -> proceed_with_request()
        {:error, :rate_limited} -> return_429()
      end
  """

  use GenServer

  @table :plugboard_rate_limit_counters

  # Default configuration
  @default_auth_limit 5
  @default_auth_window_ms 60_000
  @default_api_limit 100
  @default_api_window_ms 60_000

  ## Client API

  @doc """
  Starts the RateLimiter GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Checks if a request should be allowed based on rate limits.

  ## Parameters

    - `bucket_type` - :auth, :api, or :proxy
    - `key` - Unique identifier (IP address, API key, path_id, etc.)

  ## Returns

    - `:ok` if request is allowed
    - `{:error, :rate_limited}` if limit exceeded
  """
  @spec check(atom(), String.t()) :: :ok | {:error, :rate_limited}
  def check(bucket_type, key) do
    config = get_config(bucket_type)
    bucket_key = "#{bucket_type}:#{key}"

    case check_rate(bucket_key, config.window_ms, config.limit) do
      {:allow, _count} -> :ok
      {:deny, _limit} -> {:error, :rate_limited}
    end
  end

  @doc """
  Checks rate limit and returns the count.

  Useful for headers like X-RateLimit-Remaining.
  """
  @spec check_with_count(atom(), String.t()) ::
          {:ok, non_neg_integer()} | {:error, :rate_limited, non_neg_integer()}
  def check_with_count(bucket_type, key) do
    config = get_config(bucket_type)
    bucket_key = "#{bucket_type}:#{key}"

    case check_rate(bucket_key, config.window_ms, config.limit) do
      {:allow, count} -> {:ok, config.limit - count}
      {:deny, _limit} -> {:error, :rate_limited, 0}
    end
  end

  @doc """
  Resets the rate limit for a specific key.

  Useful after successful authentication to reset failed attempt counters.
  """
  @spec reset(atom(), String.t()) :: :ok
  def reset(bucket_type, key) do
    bucket_key = "#{bucket_type}:#{key}"
    :ets.delete(@table, bucket_key)
    :ok
  end

  @doc """
  Gets the rate limit configuration for a bucket type.

  Returns a map with `:limit` and `:window_ms` keys.

  ## Examples

      iex> RateLimiter.get_bucket_config(:auth)
      %{limit: 5, window_ms: 60000}
  """
  @spec get_bucket_config(atom()) :: %{limit: pos_integer(), window_ms: pos_integer()}
  def get_bucket_config(bucket_type), do: get_config(bucket_type)

  ## Server Callbacks

  @impl true
  def init(_opts) do
    # Create ETS table for rate limit counters
    # Using :public with write_concurrency for high-performance rate limiting
    # This is acceptable because:
    # 1. Rate limit counters are not security-sensitive data
    # 2. The worst case of a race is slightly over/under counting
    # 3. Performance is critical for rate limiting on every request
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      write_concurrency: true,
      read_concurrency: true
    ])

    # Schedule periodic cleanup of expired entries
    schedule_cleanup()

    {:ok, %{}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_expired_entries()
    schedule_cleanup()
    {:noreply, state}
  end

  ## Private Functions

  # Rate limiting using a fixed window approach with atomic operations where possible.
  #
  # Note: This implementation prioritizes performance over strict accuracy.
  # In high-concurrency scenarios, there's a small window between lookup and
  # insert where race conditions could occur. For strict rate limiting in
  # distributed systems, consider using Redis or a distributed rate limiter.
  defp check_rate(key, window_ms, limit) do
    now = System.system_time(:millisecond)
    window_start = now - window_ms

    case :ets.lookup(@table, key) do
      [{^key, count, timestamp}] when timestamp > window_start ->
        # Within current window
        if count >= limit do
          # Already at limit - deny without incrementing
          {:deny, limit}
        else
          # Try to increment atomically using update_counter
          # The {2, 1} means: increment position 2 (count) by 1
          # This is atomic and handles concurrent requests better
          try do
            new_count = :ets.update_counter(@table, key, {2, 1})

            if new_count > limit do
              # We went over the limit due to race - still deny
              # but the count is already incremented (acceptable trade-off)
              {:deny, limit}
            else
              {:allow, new_count}
            end
          rescue
            ArgumentError ->
              # Key was deleted between lookup and update_counter
              # Start a new window
              start_new_window(key, now)
          end
        end

      _ ->
        # No entry or expired window - start fresh
        start_new_window(key, now)
    end
  end

  defp start_new_window(key, timestamp) do
    # Insert new window entry
    # Race condition here is acceptable - worst case is two processes
    # both starting a new window, which just resets the counter
    :ets.insert(@table, {key, 1, timestamp})
    {:allow, 1}
  end

  defp get_config(:auth) do
    config = Application.get_env(:plugboard, __MODULE__, [])

    %{
      limit: Keyword.get(config, :auth_limit, @default_auth_limit),
      window_ms: Keyword.get(config, :auth_window_ms, @default_auth_window_ms)
    }
  end

  defp get_config(:api) do
    config = Application.get_env(:plugboard, __MODULE__, [])

    %{
      limit: Keyword.get(config, :api_limit, @default_api_limit),
      window_ms: Keyword.get(config, :api_window_ms, @default_api_window_ms)
    }
  end

  defp get_config(:proxy) do
    config = Application.get_env(:plugboard, __MODULE__, [])

    %{
      limit: Keyword.get(config, :proxy_limit, 10_000),
      window_ms: Keyword.get(config, :proxy_window_ms, 60_000)
    }
  end

  defp get_config(_) do
    %{limit: 100, window_ms: 60_000}
  end

  defp schedule_cleanup do
    # Clean up every 5 minutes
    Process.send_after(self(), :cleanup, 300_000)
  end

  defp cleanup_expired_entries do
    now = System.system_time(:millisecond)
    # Keep entries from the last hour (max window)
    cutoff = now - 3_600_000

    # Delete expired entries
    :ets.select_delete(@table, [
      {{:_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}
    ])
  end
end
