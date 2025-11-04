defmodule PlugboardWeb.TelephoneChannel do
  @moduledoc """
  Channel for telephone WebSocket communication.

  Handles telephone registration, heartbeats, token refresh, and proxy request/response.
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

      # Initialize waiting callers map and heartbeat tracking
      socket =
        socket
        |> assign(:waiting_callers, %{})
        |> assign(:last_heartbeat, System.monotonic_time(:millisecond))

      # Schedule first heartbeat check
      Process.send_after(self(), :check_heartbeat, 60_000)

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
        push(socket, "refresh_token_ack", %{token: new_jwt, expires_in: expires_in})

        Logger.debug("Token refreshed for path #{socket.assigns.path.full_path}")

        {:noreply, socket}

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
    # 60 seconds
    timeout_ms = 60_000

    if now - last_heartbeat > timeout_ms do
      Logger.warning(
        "Telephone heartbeat timeout for path #{socket.assigns.path.full_path}, disconnecting"
      )

      {:stop, :heartbeat_timeout, socket}
    else
      # Schedule next check
      Process.send_after(self(), :check_heartbeat, timeout_ms)
      {:noreply, socket}
    end
  end

  @impl true
  def terminate(reason, socket) do
    # Unregister from the registry
    TelephoneRegistry.unregister(socket.assigns.path_id, self())

    Logger.info(
      "Telephone disconnected from path #{socket.assigns.path.full_path}, reason: #{inspect(reason)}"
    )

    :ok
  end
end
