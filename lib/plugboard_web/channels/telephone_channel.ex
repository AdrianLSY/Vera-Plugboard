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

      # Update last_used_at timestamp
      TelephoneTokens.mark_token_used(socket.assigns.token_id)

      # Get token expiry config for response
      expiry_seconds = Application.get_env(:plugboard, :telephone)[:token_expiry] || 3600

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
    push(socket, "heartbeat_ack", %{ts: ts})
    {:noreply, socket}
  end

  @impl true
  def handle_in("heartbeat", _payload, socket) do
    # Handle heartbeat without timestamp
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
  def handle_in("proxy_res", payload, socket) do
    # This message is received when telephone responds to a proxy request
    # Send the response to any waiting process
    send(self(), {:send_proxy_response, payload})

    Logger.debug("Received proxy_res for path #{socket.assigns.path.full_path}")

    {:noreply, socket}
  end

  @impl true
  def handle_info({:proxy_request, from_pid, request_payload}, socket) do
    # Forward the request to the telephone client
    push(socket, "proxy_req", request_payload)

    # Store the caller PID so we can reply when we get proxy_res
    socket = assign(socket, :waiting_caller, from_pid)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:send_proxy_response, response}, socket) do
    # Send response back to the waiting caller (ProxyController)
    case Map.get(socket.assigns, :waiting_caller) do
      nil ->
        Logger.warning("Received proxy response but no waiting caller")
        {:noreply, socket}

      caller_pid ->
        send(caller_pid, {:proxy_res, response})
        # Clear the waiting caller and return
        {:noreply, assign(socket, :waiting_caller, nil)}
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
