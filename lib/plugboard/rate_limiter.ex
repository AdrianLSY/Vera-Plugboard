defmodule Plugboard.RateLimiter do
  @moduledoc """
  ETS-based rate limiting infrastructure.

  Provides rate limiting for:
  - Authentication endpoints (login, registration)
  - API endpoints (token vending, etc.)
  - Proxy requests per path

  ## Configuration

  Configure in `config/runtime.exs`:

      config :plugboard, Plugboard.RateLimiter,
        auth_limit: 5,           # requests per window
        auth_window_ms: 60_000,  # 1 minute window
        api_limit: 100,
        api_window_ms: 60_000

  ## Usage

      case RateLimiter.check(:auth, client_ip) do
        :ok -> proceed_with_request()
        {:error, :rate_limited} -> return_429()
      end
  """

  use GenServer
  require Logger

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

  ## Server Callbacks

  @impl true
  def init(_opts) do
    # Create ETS table for rate limit counters
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      write_concurrency: true,
      read_concurrency: true
    ])

    Logger.info("RateLimiter started")

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

  defp check_rate(key, window_ms, limit) do
    now = System.system_time(:millisecond)
    window_start = now - window_ms

    # Use atomic update to increment counter
    case :ets.lookup(@table, key) do
      [{^key, count, timestamp}] when timestamp > window_start ->
        # Within window, increment
        new_count = count + 1

        if new_count > limit do
          {:deny, limit}
        else
          :ets.insert(@table, {key, new_count, timestamp})
          {:allow, new_count}
        end

      _ ->
        # New window or expired - start fresh
        :ets.insert(@table, {key, 1, now})
        {:allow, 1}
    end
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
