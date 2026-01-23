defmodule PlugboardWeb.Plugs.RateLimiter do
  @moduledoc """
  Plug for rate limiting HTTP requests.

  ## Usage in Router

      plug PlugboardWeb.Plugs.RateLimiter, bucket: :auth, by: :ip

  ## Options

    - `:bucket` - Rate limit bucket (:auth, :api, :proxy)
    - `:by` - Key source (:ip, :api_key, :user_id)

  ## Response Headers

  All responses include standard rate limit headers:

    - `X-RateLimit-Limit` - Maximum requests allowed in window
    - `X-RateLimit-Remaining` - Requests remaining in current window
    - `X-RateLimit-Reset` - Unix timestamp when the window resets

  ## Examples

      # Rate limit login by IP address
      plug PlugboardWeb.Plugs.RateLimiter, bucket: :auth, by: :ip

      # Rate limit API by API key
      plug PlugboardWeb.Plugs.RateLimiter, bucket: :api, by: :api_key
  """

  import Plug.Conn

  alias Plugboard.RateLimiter

  def init(opts), do: opts

  def call(conn, opts) do
    bucket = Keyword.get(opts, :bucket, :api)
    key_source = Keyword.get(opts, :by, :ip)

    key = get_rate_limit_key(conn, key_source)
    config = RateLimiter.get_bucket_config(bucket)
    reset_timestamp = calculate_reset_timestamp(config.window_ms)

    case RateLimiter.check_with_count(bucket, key) do
      {:ok, remaining} ->
        conn
        |> put_rate_limit_headers(config.limit, remaining, reset_timestamp)

      {:error, :rate_limited, _remaining} ->
        :telemetry.execute(
          [:plugboard, :rate_limiter, :rejected],
          %{count: 1},
          %{bucket: bucket, key_source: key_source}
        )

        retry_after = div(config.window_ms, 1000)

        conn
        |> put_rate_limit_headers(config.limit, 0, reset_timestamp)
        |> put_resp_header("retry-after", to_string(retry_after))
        |> put_resp_content_type("application/json")
        |> send_resp(429, Jason.encode!(%{error: "Too many requests", retry_after: retry_after}))
        |> halt()
    end
  end

  defp put_rate_limit_headers(conn, limit, remaining, reset_timestamp) do
    conn
    |> put_resp_header("x-ratelimit-limit", to_string(limit))
    |> put_resp_header("x-ratelimit-remaining", to_string(remaining))
    |> put_resp_header("x-ratelimit-reset", to_string(reset_timestamp))
  end

  defp calculate_reset_timestamp(window_ms) do
    now_seconds = System.system_time(:second)
    now_seconds + div(window_ms, 1000)
  end

  defp get_rate_limit_key(conn, :ip) do
    conn.remote_ip
    |> :inet.ntoa()
    |> to_string()
  end

  defp get_rate_limit_key(conn, :api_key) do
    case get_req_header(conn, "x-api-key") do
      [key | _] -> key
      [] -> get_rate_limit_key(conn, :ip)
    end
  end

  defp get_rate_limit_key(conn, :user_id) do
    case conn.assigns[:current_scope] do
      %{user: %{id: user_id}} -> user_id
      _ -> get_rate_limit_key(conn, :ip)
    end
  end

  defp get_rate_limit_key(conn, _), do: get_rate_limit_key(conn, :ip)
end
