defmodule PlugboardWeb.WebSocket.ProxyHandler do
  @moduledoc """
  WebSocket handler for proxying client WebSocket connections through Telephone sidecars.

  This handler manages the lifecycle of a single proxied WebSocket connection:
  1. Receives WebSocket frames from the client
  2. Forwards them to the TelephoneChannel via Erlang messages
  3. Receives frames from the TelephoneChannel
  4. Sends them back to the client

  ## Lifecycle

  1. `init/1` - Initialize state, send ws_connect to telephone
  2. `handle_in/2` - Client sends a frame, forward to telephone
  3. `handle_info/2` - Receive messages from telephone (frames, connected, closed, error)
  4. `terminate/2` - Clean up, notify telephone of disconnect

  ## State

  The handler maintains the following state:
  - `connection_id` - Unique identifier for this connection
  - `path_id` - The mount point path ID
  - `telephone_pid` - PID of the TelephoneChannel handling this connection
  - `forwarded_path` - The path to forward to the backend
  - `connected` - Whether the backend WebSocket is connected
  - `buffer` - Frames received before backend connection established
  """

  @behaviour WebSock
  require Logger

  alias Plugboard.WebSocketProxyRegistry

  @doc """
  Initializes the WebSocket proxy handler.

  ## Parameters (in state map)

    * `:connection_id` - Pre-generated UUID for this connection
    * `:path_id` - The path ID for routing
    * `:telephone_pid` - PID of the telephone channel
    * `:forwarded_path` - Path to forward to backend
    * `:query_string` - Query string from original request
    * `:headers` - Headers to forward (subprotocols, etc.)
    * `:subprotocols` - Requested WebSocket subprotocols
  """
  @impl WebSock
  def init(state) do
    connection_id = state.connection_id
    path_id = state.path_id
    telephone_pid = state.telephone_pid

    Logger.info(
      "WebSocket proxy handler started for connection #{connection_id}, path #{path_id}"
    )

    # Register this connection
    :ok = WebSocketProxyRegistry.register(connection_id, self(), path_id, telephone_pid)

    # Send ws_connect to telephone channel
    send(
      telephone_pid,
      {:ws_connect, self(), connection_id,
       %{
         path: state.forwarded_path,
         query_string: state.query_string,
         headers: state.headers
       }}
    )

    :telemetry.execute(
      [:plugboard, :websocket_proxy, :connect],
      %{count: 1},
      %{connection_id: connection_id, path_id: path_id}
    )

    # Start in "connecting" state - buffer frames until backend connects
    {:ok,
     %{
       connection_id: connection_id,
       path_id: path_id,
       telephone_pid: telephone_pid,
       connected: false,
       buffer: [],
       connect_timeout_ref: schedule_connect_timeout()
     }}
  end

  @doc """
  Handles incoming WebSocket frames from the client.
  """
  @impl WebSock
  def handle_in({data, opcode: opcode}, state) do
    if state.connected do
      # Forward frame to telephone
      forward_frame_to_telephone(state, opcode, data)
      {:ok, state}
    else
      # Buffer frame until backend connects
      Logger.debug("Buffering frame for connection #{state.connection_id} (not yet connected)")
      {:ok, %{state | buffer: state.buffer ++ [{opcode, data}]}}
    end
  end

  @doc """
  Handles messages from the TelephoneChannel and other processes.
  """
  @impl WebSock

  # Backend WebSocket connected successfully
  def handle_info(
        {:ws_connected, connection_id, response},
        %{connection_id: connection_id} = state
      ) do
    Logger.info("Backend WebSocket connected for #{connection_id}")

    # Cancel connect timeout
    if state.connect_timeout_ref, do: Process.cancel_timer(state.connect_timeout_ref)

    :telemetry.execute(
      [:plugboard, :websocket_proxy, :backend_connected],
      %{count: 1},
      %{connection_id: connection_id, path_id: state.path_id}
    )

    # Flush buffered frames
    state = %{state | connected: true, connect_timeout_ref: nil}

    Enum.each(state.buffer, fn {opcode, data} ->
      forward_frame_to_telephone(state, opcode, data)
    end)

    # If response contains subprotocol info, we can't change it now (already upgraded)
    # Just log it for debugging
    if protocol = response["protocol"] do
      Logger.debug("Backend selected subprotocol: #{protocol}")
    end

    {:ok, %{state | buffer: []}}
  end

  # Frame from backend (via telephone)
  def handle_info(
        {:ws_frame, connection_id, opcode, data},
        %{connection_id: connection_id} = state
      ) do
    Logger.debug("Received frame from backend for #{connection_id}, opcode: #{opcode}")

    :telemetry.execute(
      [:plugboard, :websocket_proxy, :frame_from_backend],
      %{bytes: byte_size(data)},
      %{connection_id: connection_id, path_id: state.path_id, opcode: opcode}
    )

    # Send frame to client
    frame = build_frame(opcode, data)
    {:push, frame, state}
  end

  # Backend WebSocket closed
  def handle_info(
        {:ws_closed, connection_id, code, reason},
        %{connection_id: connection_id} = state
      ) do
    Logger.info("Backend WebSocket closed for #{connection_id}: #{code} - #{reason}")

    :telemetry.execute(
      [:plugboard, :websocket_proxy, :backend_closed],
      %{count: 1},
      %{connection_id: connection_id, path_id: state.path_id, code: code}
    )

    # Close client connection with same code
    {:stop, :normal, {code, reason}, state}
  end

  # Error connecting to backend
  def handle_info({:ws_error, connection_id, reason}, %{connection_id: connection_id} = state) do
    Logger.error("Backend WebSocket error for #{connection_id}: #{reason}")

    :telemetry.execute(
      [:plugboard, :websocket_proxy, :backend_error],
      %{count: 1},
      %{connection_id: connection_id, path_id: state.path_id, reason: reason}
    )

    # Close client connection with bad gateway code
    {:stop, :normal, {1014, "Bad Gateway: #{reason}"}, state}
  end

  # Telephone disconnected
  def handle_info(
        {:telephone_disconnected, connection_id},
        %{connection_id: connection_id} = state
      ) do
    Logger.warning("Telephone disconnected for WebSocket #{connection_id}")

    :telemetry.execute(
      [:plugboard, :websocket_proxy, :telephone_disconnected],
      %{count: 1},
      %{connection_id: connection_id, path_id: state.path_id}
    )

    # Close client connection
    {:stop, :normal, {1001, "Telephone sidecar disconnected"}, state}
  end

  # Connect timeout
  def handle_info(:connect_timeout, state) do
    Logger.warning("Backend WebSocket connect timeout for #{state.connection_id}")

    :telemetry.execute(
      [:plugboard, :websocket_proxy, :connect_timeout],
      %{count: 1},
      %{connection_id: state.connection_id, path_id: state.path_id}
    )

    # Notify telephone to cancel connection attempt
    send(state.telephone_pid, {:ws_close, state.connection_id, 1014, "Connect timeout"})

    {:stop, :normal, {1014, "Backend connection timeout"}, state}
  end

  # Ignore unknown messages
  def handle_info(msg, state) do
    Logger.debug("WebSocket proxy handler received unknown message: #{inspect(msg)}")
    {:ok, state}
  end

  @doc """
  Called when the WebSocket connection is terminated.
  """
  @impl WebSock
  def terminate(reason, state) do
    Logger.info(
      "WebSocket proxy handler terminating for #{state.connection_id}: #{inspect(reason)}"
    )

    # Unregister from registry
    WebSocketProxyRegistry.unregister(state.connection_id)

    # Notify telephone that client disconnected (if we were connected)
    if state.connected do
      send(state.telephone_pid, {:ws_close, state.connection_id, 1000, "Client disconnected"})
    end

    :telemetry.execute(
      [:plugboard, :websocket_proxy, :disconnect],
      %{count: 1},
      %{connection_id: state.connection_id, path_id: state.path_id, reason: inspect(reason)}
    )

    :ok
  end

  ## Private Functions

  defp forward_frame_to_telephone(state, opcode, data) do
    :telemetry.execute(
      [:plugboard, :websocket_proxy, :frame_to_backend],
      %{bytes: byte_size(data)},
      %{connection_id: state.connection_id, path_id: state.path_id, opcode: opcode}
    )

    send(state.telephone_pid, {:ws_frame, state.connection_id, opcode, data})
  end

  defp build_frame(:text, data), do: {:text, data}
  defp build_frame(:binary, data), do: {:binary, data}
  defp build_frame(:ping, data), do: {:ping, data}
  defp build_frame(:pong, data), do: {:pong, data}
  defp build_frame(opcode, data) when is_atom(opcode), do: {opcode, data}
  # Handle string opcodes from telephone
  defp build_frame("text", data), do: {:text, data}
  defp build_frame("binary", data), do: {:binary, data}
  defp build_frame("ping", data), do: {:ping, data}
  defp build_frame("pong", data), do: {:pong, data}

  defp schedule_connect_timeout do
    timeout = Application.get_env(:plugboard, :websocket_proxy)[:connect_timeout_ms] || 5000
    Process.send_after(self(), :connect_timeout, timeout)
  end
end
