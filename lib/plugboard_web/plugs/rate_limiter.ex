defmodule PlugboardWeb.Plugs.RateLimiter do
  @moduledoc """
  Plug for rate limiting HTTP requests.

  ## Usage in Router

      plug PlugboardWeb.Plugs.RateLimiter, bucket: :auth, by: :ip

  ## Options

    - `:bucket` - Rate limit bucket (:auth, :api, :proxy)
    - `:by` - Key source (:ip, :api_key, :user_id)

  ## Examples

      # Rate limit login by IP address
      plug PlugboardWeb.Plugs.RateLimiter, bucket: :auth, by: :ip

      # Rate limit API by API key
      plug PlugboardWeb.Plugs.RateLimiter, bucket: :api, by: :api_key
  """

  import Plug.Conn
  require Logger

  alias Plugboard.RateLimiter

  def init(opts), do: opts

  def call(conn, opts) do
    bucket = Keyword.get(opts, :bucket, :api)
    key_source = Keyword.get(opts, :by, :ip)

    key = get_rate_limit_key(conn, key_source)

    case RateLimiter.check_with_count(bucket, key) do
      {:ok, remaining} ->
        conn
        |> put_resp_header("x-ratelimit-remaining", to_string(remaining))

      {:error, :rate_limited, _remaining} ->
        Logger.warning("Rate limited request: bucket=#{bucket} key=#{key}")

        :telemetry.execute(
          [:plugboard, :rate_limiter, :rejected],
          %{count: 1},
          %{bucket: bucket, key_source: key_source}
        )

        conn
        |> put_resp_header("x-ratelimit-remaining", "0")
        |> put_resp_header("retry-after", "60")
        |> put_resp_content_type("application/json")
        |> send_resp(429, Jason.encode!(%{error: "Too many requests", retry_after: 60}))
        |> halt()
    end
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
