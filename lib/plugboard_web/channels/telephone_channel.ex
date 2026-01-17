defmodule PlugboardWeb.TelephoneChannel do
  @moduledoc """
  Channel for telephone WebSocket communication.

  Handles telephone registration, heartbeats, token refresh, proxy request/response,
  and WebSocket proxy connections.

  ## WebSocket Proxy Support

  This channel also handles proxied WebSocket connections from clients. Each proxied
  WebSocket connection is tracked by a unique `connection_id` and managed by a
  `WebSocketProxyHandler` process.

  ### Message Flow

  **Plugboard -> Telephone (outgoing events):**
  - `ws_connect` - Request to open WebSocket to backend
  - `ws_frame` - Forward frame from client to backend
  - `ws_close` - Client closed connection

  **Telephone -> Plugboard (incoming events):**
  - `ws_connected` - Backend WebSocket established
  - `ws_frame` - Frame from backend to forward to client
  - `ws_closed` - Backend closed connection
  - `ws_error` - Error occurred
  """

  use PlugboardWeb, :channel

  require Logger

  alias Plugboard.TelephoneRegistry
  alias Plugboard.TelephoneTokens

  @impl true
  def join("telephone:" <> path_id, _payload, socket) do
    if socket.assigns.path_id == path_id do
      # Register this telephone in the registry
      :ok = TelephoneRegistry.register(path_id, self())

      # Note: last_used_at is already updated by validate_and_mark_used in socket.connect
      # No need to call mark_token_used again here

      # Get token expiry config for response
      expiry_seconds = Application.get_env(:plugboard, :telephone)[:token_expiry] || 3600

      # Get heartbeat config for scheduling checks
      heartbeat_timeout_ms =
        Application.get_env(:plugboard, :telephone)[:heartbeat_timeout_ms] || 60_000

      # Check at half the timeout interval for better detection
      heartbeat_check_interval = div(heartbeat_timeout_ms, 2)

      # Initialize waiting callers map, WebSocket connections map, and heartbeat tracking
      socket =
        socket
        |> assign(:waiting_callers, %{})
        |> assign(:ws_connections, %{})
        |> assign(:last_heartbeat, System.monotonic_time(:millisecond))
        |> assign(:heartbeat_check_interval, heartbeat_check_interval)

      # Schedule first heartbeat check at half the timeout interval
      Process.send_after(self(), :check_heartbeat, heartbeat_check_interval)

      # Emit telemetry
      :telemetry.execute(
        [:plugboard, :telephone, :connected],
        %{count: 1},
        %{path_id: path_id, path: socket.assigns.path.full_path}
      )

      Logger.info(
        "Telephone joined channel for path #{socket.assigns.path.full_path} (#{path_id})"
      )

      # Send acknowledgment with path info
      {:ok,
       %{
         status: "ok",
         path: socket.assigns.path.full_path,
         expires_in: expiry_seconds
       }, socket}
    else
      Logger.error("Path ID mismatch: socket=#{socket.assigns.path_id}, channel=#{path_id}")
      {:error, %{reason: "path_id_mismatch"}}
    end
  end

  @impl true
  def handle_in("heartbeat", %{"ts" => ts}, socket) do
    # Update last heartbeat timestamp
    socket = assign(socket, :last_heartbeat, System.monotonic_time(:millisecond))
    push(socket, "heartbeat_ack", %{ts: ts})
    {:noreply, socket}
  end

  @impl true
  def handle_in("heartbeat", _payload, socket) do
    # Handle heartbeat without timestamp
    socket = assign(socket, :last_heartbeat, System.monotonic_time(:millisecond))
    push(socket, "heartbeat_ack", %{ts: DateTime.utc_now() |> DateTime.to_unix()})
    {:noreply, socket}
  end

  @impl true
  def handle_in("refresh_token", _payload, socket) do
    case TelephoneTokens.refresh_token(socket.assigns.token_id) do
      {:ok, new_jwt, expires_in} ->
        Logger.debug("Token refreshed for path #{socket.assigns.path.full_path}")

        {:reply, {:ok, %{token: new_jwt, expires_in: expires_in}}, socket}

      {:error, reason} ->
        Logger.error("Token refresh failed: #{inspect(reason)}")
        {:reply, {:error, %{reason: inspect(reason)}}, socket}
    end
  end

  @impl true
  def handle_in("proxy_res", %{"request_id" => request_id} = payload, socket) do
    # This message is received when telephone responds to a proxy request
    # Extract request_id and send response to the correct waiting caller
    send(self(), {:send_proxy_response, request_id, payload})

    Logger.debug(
      "Received proxy_res for request #{request_id} on path #{socket.assigns.path.full_path}"
    )

    {:noreply, socket}
  end

  @impl true
  def handle_in("proxy_res", payload, socket) do
    # Handle legacy proxy_res without request_id (should not happen in Phase 3+)
    Logger.warning("Received proxy_res without request_id, ignoring: #{inspect(payload)}")
    {:noreply, socket}
  end

  # =============================================================================
  # WebSocket Proxy Events (from Telephone sidecar)
  # =============================================================================

  @impl true
  def handle_in("ws_connected", %{"connection_id" => connection_id} = payload, socket) do
    # Backend WebSocket connected - notify the handler
    ws_connections = Map.get(socket.assigns, :ws_connections, %{})

    case Map.get(ws_connections, connection_id) do
      nil ->
        Logger.warning("Received ws_connected for unknown connection: #{connection_id}")
        {:noreply, socket}

      handler_pid ->
        send(handler_pid, {:ws_connected, connection_id, payload})

        Logger.debug(
          "WebSocket backend connected for #{connection_id} on path #{socket.assigns.path.full_path}"
        )

        {:noreply, socket}
    end
  end

  @impl true
  def handle_in(
        "ws_frame",
        %{"connection_id" => connection_id, "opcode" => opcode, "data" => data},
        socket
      ) do
    # Frame from backend - forward to handler
    ws_connections = Map.get(socket.assigns, :ws_connections, %{})

    case Map.get(ws_connections, connection_id) do
      nil ->
        Logger.warning("Received ws_frame for unknown connection: #{connection_id}")
        {:noreply, socket}

      handler_pid ->
        # Decode base64 data if needed
        decoded_data = decode_frame_data(data)
        send(handler_pid, {:ws_frame, connection_id, opcode, decoded_data})
        {:noreply, socket}
    end
  end

  @impl true
  def handle_in("ws_closed", %{"connection_id" => connection_id} = payload, socket) do
    # Backend closed WebSocket - notify handler and clean up
    ws_connections = Map.get(socket.assigns, :ws_connections, %{})
    code = payload["code"] || 1000
    reason = payload["reason"] || "Backend closed connection"

    case Map.get(ws_connections, connection_id) do
      nil ->
        Logger.debug("Received ws_closed for already closed connection: #{connection_id}")
        {:noreply, socket}

      handler_pid ->
        send(handler_pid, {:ws_closed, connection_id, code, reason})

        Logger.info("WebSocket backend closed for #{connection_id}: #{code} - #{reason}")

        # Remove from connections map
        updated_connections = Map.delete(ws_connections, connection_id)
        {:noreply, assign(socket, :ws_connections, updated_connections)}
    end
  end

  @impl true
  def handle_in("ws_error", %{"connection_id" => connection_id, "reason" => reason}, socket) do
    # Error from backend - notify handler
    ws_connections = Map.get(socket.assigns, :ws_connections, %{})

    case Map.get(ws_connections, connection_id) do
      nil ->
        Logger.warning("Received ws_error for unknown connection: #{connection_id}")
        {:noreply, socket}

      handler_pid ->
        send(handler_pid, {:ws_error, connection_id, reason})

        Logger.error(
          "WebSocket backend error for #{connection_id} on path #{socket.assigns.path.full_path}: #{reason}"
        )

        # Remove from connections map
        updated_connections = Map.delete(ws_connections, connection_id)
        {:noreply, assign(socket, :ws_connections, updated_connections)}
    end
  end

  # =============================================================================
  # HTTP Proxy Messages (from ProxyController)
  # =============================================================================

  @impl true
  def handle_info({:proxy_request, from_pid, request_id, request_payload}, socket) do
    # Forward the request to the telephone client with correlation ID
    push(socket, "proxy_req", request_payload)

    # Store the caller PID mapped by request_id (supports concurrent requests)
    waiting_callers = Map.get(socket.assigns, :waiting_callers, %{})
    socket = assign(socket, :waiting_callers, Map.put(waiting_callers, request_id, from_pid))

    Logger.debug(
      "Stored waiting caller for request #{request_id}, total waiting: #{map_size(waiting_callers) + 1}"
    )

    {:noreply, socket}
  end

  @impl true
  def handle_info({:send_proxy_response, request_id, response}, socket) do
    # Send response back to the correct waiting caller using correlation ID
    waiting_callers = Map.get(socket.assigns, :waiting_callers, %{})

    case Map.get(waiting_callers, request_id) do
      nil ->
        Logger.warning("Received proxy response for unknown request_id: #{request_id}")
        {:noreply, socket}

      caller_pid ->
        send(caller_pid, {:proxy_res, request_id, response})
        # Remove this caller from the waiting map
        updated_callers = Map.delete(waiting_callers, request_id)
        {:noreply, assign(socket, :waiting_callers, updated_callers)}
    end
  end

  @impl true
  def handle_info(:check_heartbeat, socket) do
    # Check if heartbeat timeout has been exceeded
    last_heartbeat = Map.get(socket.assigns, :last_heartbeat, 0)
    now = System.monotonic_time(:millisecond)
    # Configurable via TELEPHONE_HEARTBEAT_TIMEOUT_MS env var (default: 60 seconds)
    timeout_ms = Application.get_env(:plugboard, :telephone)[:heartbeat_timeout_ms] || 60_000

    if now - last_heartbeat > timeout_ms do
      Logger.warning(
        "Telephone heartbeat timeout for path #{socket.assigns.path.full_path}, disconnecting"
      )

      {:stop, :heartbeat_timeout, socket}
    else
      # Schedule next check at the stored interval (half of timeout)
      check_interval = Map.get(socket.assigns, :heartbeat_check_interval, div(timeout_ms, 2))
      Process.send_after(self(), :check_heartbeat, check_interval)
      {:noreply, socket}
    end
  end

  # =============================================================================
  # WebSocket Proxy Messages (from WebSocketProxyHandler)
  # =============================================================================

  @impl true
  def handle_info({:ws_connect, handler_pid, connection_id, params}, socket) do
    # Client wants to establish WebSocket to backend
    Logger.info(
      "WebSocket connect request #{connection_id} for path #{params.path} on #{socket.assigns.path.full_path}"
    )

    # Store the handler PID
    ws_connections = Map.get(socket.assigns, :ws_connections, %{})
    socket = assign(socket, :ws_connections, Map.put(ws_connections, connection_id, handler_pid))

    # Monitor the handler process for cleanup
    Process.monitor(handler_pid)

    # Forward to telephone
    push(socket, "ws_connect", %{
      "connection_id" => connection_id,
      "path" => params.path,
      "query_string" => params.query_string,
      "headers" => params.headers
    })

    :telemetry.execute(
      [:plugboard, :telephone, :ws_connect],
      %{count: 1},
      %{path_id: socket.assigns.path_id, connection_id: connection_id}
    )

    {:noreply, socket}
  end

  @impl true
  def handle_info({:ws_frame, connection_id, opcode, data}, socket) do
    # Frame from client to forward to backend
    # Encode binary data as base64 for JSON transport
    encoded_data = encode_frame_data(data)

    push(socket, "ws_frame", %{
      "connection_id" => connection_id,
      "opcode" => to_string(opcode),
      "data" => encoded_data
    })

    {:noreply, socket}
  end

  @impl true
  def handle_info({:ws_close, connection_id, code, reason}, socket) do
    # Client closed WebSocket or timeout
    ws_connections = Map.get(socket.assigns, :ws_connections, %{})

    push(socket, "ws_close", %{
      "connection_id" => connection_id,
      "code" => code,
      "reason" => reason
    })

    Logger.info("WebSocket close sent for #{connection_id}: #{code} - #{reason}")

    # Remove from connections map
    updated_connections = Map.delete(ws_connections, connection_id)
    {:noreply, assign(socket, :ws_connections, updated_connections)}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, socket) do
    # WebSocket handler process died - clean up its connection
    ws_connections = Map.get(socket.assigns, :ws_connections, %{})

    case find_connection_by_handler(ws_connections, pid) do
      nil ->
        {:noreply, socket}

      connection_id ->
        Logger.debug("WebSocket handler for #{connection_id} died, cleaning up")

        # Notify telephone to close backend connection
        push(socket, "ws_close", %{
          "connection_id" => connection_id,
          "code" => 1001,
          "reason" => "Handler process terminated"
        })

        updated_connections = Map.delete(ws_connections, connection_id)
        {:noreply, assign(socket, :ws_connections, updated_connections)}
    end
  end

  @impl true
  def terminate(reason, socket) do
    # Unregister from the registry
    TelephoneRegistry.unregister(socket.assigns.path_id, self())

    # Notify all waiting callers that the telephone disconnected
    waiting_callers = Map.get(socket.assigns, :waiting_callers, %{})

    if map_size(waiting_callers) > 0 do
      Logger.warning(
        "Telephone disconnected with #{map_size(waiting_callers)} pending requests for path #{socket.assigns.path.full_path}"
      )

      # Notify each waiting caller with disconnect error
      Enum.each(waiting_callers, fn {request_id, caller_pid} ->
        send(caller_pid, {:proxy_error, request_id, :telephone_disconnected})
      end)
    end

    # Notify all WebSocket proxy handlers that telephone disconnected
    ws_connections = Map.get(socket.assigns, :ws_connections, %{})

    if map_size(ws_connections) > 0 do
      Logger.warning(
        "Telephone disconnected with #{map_size(ws_connections)} active WebSocket connections for path #{socket.assigns.path.full_path}"
      )

      # Notify each WebSocket handler
      Enum.each(ws_connections, fn {connection_id, handler_pid} ->
        send(handler_pid, {:telephone_disconnected, connection_id})
      end)
    end

    # Emit telemetry
    :telemetry.execute(
      [:plugboard, :telephone, :disconnected],
      %{
        count: 1,
        pending_requests: map_size(waiting_callers),
        ws_connections: map_size(ws_connections)
      },
      %{path_id: socket.assigns.path_id, path: socket.assigns.path.full_path, reason: reason}
    )

    Logger.info(
      "Telephone disconnected from path #{socket.assigns.path.full_path}, reason: #{inspect(reason)}"
    )

    :ok
  end

  # =============================================================================
  # Private Helper Functions
  # =============================================================================

  defp encode_frame_data(data) when is_binary(data), do: Base.encode64(data)
  defp encode_frame_data(data), do: to_string(data)

  defp decode_frame_data(data) when is_binary(data) do
    case Base.decode64(data) do
      {:ok, decoded} -> decoded
      :error -> data
    end
  end

  defp decode_frame_data(data), do: to_string(data)

  defp find_connection_by_handler(ws_connections, handler_pid) do
    ws_connections
    |> Enum.find(fn {_conn_id, pid} -> pid == handler_pid end)
    |> case do
      {connection_id, _pid} -> connection_id
      nil -> nil
    end
  end
end
