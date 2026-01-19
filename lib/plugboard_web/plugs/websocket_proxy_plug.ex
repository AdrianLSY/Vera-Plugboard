defmodule PlugboardWeb.Plugs.WebSocketProxyPlug do
  @moduledoc """
  Plug that intercepts WebSocket upgrade requests and proxies them through Telephone sidecars.

  This plug detects WebSocket upgrade requests, matches them to mount points (either by
  path prefix `/call/*` or by domain affinity), and upgrades the connection to a WebSocket
  that proxies through to the backend via the Telephone sidecar.

  ## Routing

  WebSocket requests are matched using the same logic as HTTP requests:

  1. **Path-based routing** (`/call/abc/xyz/websocket`):
     - Strips `/call` prefix
     - Uses `MountStore.match/1` for longest prefix match
     - Forwards remaining path to backend

  2. **Domain-based routing** (`xyz.example.com/websocket`):
     - Uses `MountStore.match_by_domain/1`
     - Forwards entire path to backend

  ## Transparent Subprotocol Support

  The plug transparently forwards WebSocket subprotocol negotiation:
  - Captures `Sec-WebSocket-Protocol` header from client
  - Forwards to Telephone which negotiates with backend
  - Backend's selected subprotocol is used in handshake response

  ## Configuration

  Configure in `config/runtime.exs`:

      config :plugboard, :websocket_proxy,
        enabled: true,
        connect_timeout_ms: 5000,
        max_frame_size: 1_048_576,
        idle_timeout_ms: 300_000

  ## Example

      # In endpoint.ex (before router)
      plug PlugboardWeb.Plugs.WebSocketProxyPlug
      plug PlugboardWeb.Router
  """

  @behaviour Plug

  import Plug.Conn
  require Logger

  alias Plugboard.MountStore
  alias Plugboard.TelephoneRegistry
  alias PlugboardWeb.WebSocket.ProxyHandler

  # List of paths/prefixes that should NOT be proxied (admin routes, etc.)
  @excluded_prefixes [
    "/live",
    "/phoenix",
    "/telephone",
    "/api",
    "/users",
    "/dev",
    "/paths",
    "/assets"
  ]

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    if websocket_upgrade?(conn) and proxy_enabled?() and not excluded_path?(conn) do
      handle_websocket_upgrade(conn)
    else
      conn
    end
  end

  ## Private Functions

  defp websocket_upgrade?(conn) do
    # Check for WebSocket upgrade headers
    upgrade_header =
      conn
      |> get_req_header("upgrade")
      |> List.first()
      |> to_string()
      |> String.downcase()

    connection_header =
      conn
      |> get_req_header("connection")
      |> List.first()
      |> to_string()
      |> String.downcase()

    upgrade_header == "websocket" and String.contains?(connection_header, "upgrade")
  end

  defp proxy_enabled? do
    Application.get_env(:plugboard, :websocket_proxy)[:enabled] != false
  end

  defp excluded_path?(conn) do
    Enum.any?(@excluded_prefixes, fn prefix ->
      String.starts_with?(conn.request_path, prefix)
    end)
  end

  defp handle_websocket_upgrade(conn) do
    # Try path-based routing first (for /call/* paths)
    # Then try domain-based routing
    #
    # NOTE: We pass the telephone_pid through from match_route to avoid a race
    # condition where the telephone could become unavailable between the match
    # check and the upgrade. By capturing the PID once and reusing it, we
    # minimize the window for the telephone to disconnect.
    case match_route(conn) do
      {:ok, path_id, forwarded_path, telephone_pid} ->
        # NEW: Check backend BEFORE upgrading browser connection
        # This ensures transparency - backend's protocol selection is used
        case check_backend_websocket_support(conn, telephone_pid, path_id, forwarded_path) do
          {:ok, backend_info} ->
            # Backend confirmed support, now upgrade with correct protocol
            Logger.info(
              "Backend WebSocket check succeeded for #{path_id}, protocol: #{inspect(backend_info.protocol)}"
            )

            upgrade_to_websocket(conn, path_id, forwarded_path, telephone_pid, backend_info)

          {:error, :timeout} ->
            Logger.error("Backend WebSocket check timeout for path #{path_id}")

            conn
            |> put_resp_content_type("application/json")
            |> send_resp(504, Jason.encode!(%{error: "Backend check timeout"}))
            |> halt()

          {:error, reason} when is_binary(reason) ->
            Logger.error("Backend doesn't support WebSocket: #{reason}")

            conn
            |> put_resp_content_type("application/json")
            |> send_resp(
              502,
              Jason.encode!(%{error: "Backend WebSocket not supported", reason: reason})
            )
            |> halt()

          {:error, reason} ->
            Logger.error("Backend WebSocket check failed: #{inspect(reason)}")

            conn
            |> put_resp_content_type("application/json")
            |> send_resp(502, Jason.encode!(%{error: "Backend check failed"}))
            |> halt()
        end

      {:error, :not_found} ->
        # No match - let the request continue to normal routing
        # which will return 404 or be handled by other routes
        conn

      {:error, :no_telephone} ->
        # Mount point exists but no telephone available
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(503, Jason.encode!(%{error: "No telephone available for WebSocket proxy"}))
        |> halt()
    end
  end

  defp match_route(conn) do
    # Path-based routing: /call/*
    if String.starts_with?(conn.request_path, "/call/") do
      match_by_path(conn)
    else
      # Domain-based routing
      match_by_domain(conn)
    end
  end

  # Check if backend supports WebSocket before upgrading browser connection.
  # This ensures transparency - backend's protocol selection is used in browser upgrade.
  defp check_backend_websocket_support(conn, telephone_pid, path_id, forwarded_path) do
    # Extract headers to forward
    headers = extract_websocket_headers(conn)

    # Build check request
    check_request = %{
      path: forwarded_path,
      query_string: conn.query_string,
      headers: headers
    }

    Logger.debug("Checking backend WebSocket support for path #{path_id}: #{forwarded_path}")

    # Get timeout from path config first, fall back to env default
    timeout =
      get_path_timeout(path_id) ||
        Application.get_env(:plugboard, :websocket_proxy)[:check_timeout_ms] ||
        5000

    Logger.debug("Using WebSocket check timeout: #{timeout}ms")

    # Make SYNCHRONOUS call to TelephoneChannel
    try do
      GenServer.call(telephone_pid, {:check_ws_support, check_request}, timeout)
    catch
      :exit, {:timeout, _} ->
        Logger.error("Backend WebSocket check timeout for path #{path_id} after #{timeout}ms")
        {:error, :timeout}

      :exit, {:noproc, _} ->
        Logger.error("Telephone process died during WebSocket check for path #{path_id}")
        {:error, :telephone_died}

      :exit, reason ->
        Logger.error("Backend WebSocket check failed for path #{path_id}: #{inspect(reason)}")
        {:error, {:telephone_error, reason}}
    end
  end

  # Get per-path timeout override from database
  defp get_path_timeout(path_id) do
    case Plugboard.Repo.get(Plugboard.Paths.Path, path_id) do
      %{check_timeout_ms: timeout} when is_integer(timeout) and timeout > 0 ->
        Logger.debug("Using per-path timeout for #{path_id}: #{timeout}ms")
        timeout

      _ ->
        nil
    end
  end

  defp match_by_path(conn) do
    # Strip /call prefix to get the path for matching
    request_path = String.replace_prefix(conn.request_path, "/call", "")

    case MountStore.match(request_path) do
      {:ok, {_mount_path, forwarded_path, mount_id}} ->
        case TelephoneRegistry.get_telephone(mount_id) do
          {:ok, telephone_pid} ->
            # Return the telephone_pid to avoid a second lookup in upgrade_to_websocket
            {:ok, mount_id, forwarded_path, telephone_pid}

          {:error, :no_telephone} ->
            {:error, :no_telephone}
        end

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  defp match_by_domain(conn) do
    case MountStore.match_by_domain(conn.host) do
      {:ok, {path_id, _full_path}} ->
        case TelephoneRegistry.get_telephone(path_id) do
          {:ok, telephone_pid} ->
            # For domain affinity, forward the entire request path
            # Return the telephone_pid to avoid a second lookup in upgrade_to_websocket
            {:ok, path_id, conn.request_path, telephone_pid}

          {:error, :no_telephone} ->
            {:error, :no_telephone}
        end

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  # Upgrades the connection to a WebSocket proxy.
  #
  # The telephone_pid is passed in from match_route to avoid a race condition
  # where we'd need to look up the telephone again. While the telephone could
  # still disconnect between the match and upgrade, this minimizes the window.
  # The ProxyHandler will detect if the telephone is unavailable during init.
  #
  # The backend_info contains the protocol selected by the backend during the
  # pre-check, ensuring transparent protocol negotiation.
  defp upgrade_to_websocket(conn, path_id, forwarded_path, telephone_pid, backend_info) do
    connection_id = Ecto.UUID.generate()

    Logger.info(
      "Upgrading WebSocket connection #{connection_id} for path #{path_id}, " <>
        "forwarding to #{forwarded_path}, backend protocol: #{inspect(backend_info.protocol)}"
    )

    # Extract headers to forward (including subprotocols)
    headers = extract_websocket_headers(conn)
    subprotocols = get_req_header(conn, "sec-websocket-protocol")

    # Build initial state for handler
    handler_state = %{
      connection_id: connection_id,
      path_id: path_id,
      telephone_pid: telephone_pid,
      forwarded_path: forwarded_path,
      query_string: conn.query_string,
      headers: headers,
      subprotocols: subprotocols,
      # NEW: Pass backend's chosen protocol
      backend_protocol: backend_info.protocol
    }

    # Get WebSocket options from config
    # NEW: Use backend's protocol, not client's requested list
    ws_opts = build_websocket_options_with_protocol(backend_info.protocol)

    # Upgrade to WebSocket
    conn
    |> WebSockAdapter.upgrade(ProxyHandler, handler_state, ws_opts)
    |> halt()
  end

  defp extract_websocket_headers(conn) do
    # Extract headers that should be forwarded to the backend
    forwarded_headers = [
      "sec-websocket-protocol",
      "sec-websocket-extensions",
      "origin",
      "cookie",
      "authorization",
      "x-forwarded-for",
      "x-real-ip",
      "x-request-id"
    ]

    conn.req_headers
    |> Enum.filter(fn {key, _value} ->
      String.downcase(key) in forwarded_headers
    end)
    |> Map.new()
  end

  defp build_websocket_options(subprotocols) do
    config = Application.get_env(:plugboard, :websocket_proxy) || []

    opts = [
      timeout: config[:idle_timeout_ms] || 300_000,
      max_frame_size: config[:max_frame_size] || 1_048_576,
      compress: true
    ]

    # Add subprotocols if client requested any
    case subprotocols do
      [protocols] when is_binary(protocols) ->
        # Parse comma-separated list of protocols
        protocol_list =
          protocols
          |> String.split(",")
          |> Enum.map(&String.trim/1)

        Keyword.put(opts, :subprotocols, protocol_list)

      _ ->
        opts
    end
  end

  # Build WebSocket options with specific protocol from backend
  # This ensures transparent protocol negotiation - backend's choice is used
  defp build_websocket_options_with_protocol(nil) do
    # Backend didn't select a protocol
    config = Application.get_env(:plugboard, :websocket_proxy) || []

    [
      timeout: config[:idle_timeout_ms] || 300_000,
      max_frame_size: config[:max_frame_size] || 1_048_576,
      compress: true
    ]
  end

  defp build_websocket_options_with_protocol(protocol)
       when is_binary(protocol) and protocol != "" do
    # Backend selected a protocol - use it for transparent proxying!
    config = Application.get_env(:plugboard, :websocket_proxy) || []

    [
      timeout: config[:idle_timeout_ms] || 300_000,
      max_frame_size: config[:max_frame_size] || 1_048_576,
      compress: true,
      # Use backend's selected protocol
      subprotocols: [protocol]
    ]
  end

  defp build_websocket_options_with_protocol("") do
    # Empty string means no protocol
    build_websocket_options_with_protocol(nil)
  end
end
