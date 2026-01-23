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

  alias Plugboard.WebSocketProxyRegistry

  # Buffer limits to prevent memory exhaustion attacks
  @max_buffer_frames 100
  @max_buffer_bytes 1_048_576

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
    # backend_protocol is passed through state but used by the plug for header setting
    _backend_protocol = Map.get(state, :backend_protocol)

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

    # Build handler state
    handler_state = %{
      connection_id: connection_id,
      path_id: path_id,
      telephone_pid: telephone_pid,
      connected: false,
      buffer: [],
      connect_timeout_ref: schedule_connect_timeout()
    }

    {:ok, handler_state}
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
      # Buffer frame until backend connects (with limits to prevent memory exhaustion)
      buffer_frame(state, opcode, data)
    end
  end

  # Buffer frame with size limits to prevent memory exhaustion attacks
  defp buffer_frame(state, opcode, data) do
    current_buffer_bytes =
      Enum.reduce(state.buffer, 0, fn {_op, d}, acc -> acc + byte_size(d) end)

    new_buffer_bytes = current_buffer_bytes + byte_size(data)
    new_buffer_count = length(state.buffer) + 1

    cond do
      new_buffer_count > @max_buffer_frames ->
        :telemetry.execute(
          [:plugboard, :websocket_proxy, :buffer_overflow],
          %{count: 1},
          %{connection_id: state.connection_id, path_id: state.path_id, reason: :frame_count}
        )

        {:stop, :normal, {1009, "Buffer overflow: too many frames"}, state}

      new_buffer_bytes > @max_buffer_bytes ->
        :telemetry.execute(
          [:plugboard, :websocket_proxy, :buffer_overflow],
          %{count: 1},
          %{connection_id: state.connection_id, path_id: state.path_id, reason: :byte_size}
        )

        {:stop, :normal, {1009, "Buffer overflow: message too large"}, state}

      true ->
        {:ok, %{state | buffer: state.buffer ++ [{opcode, data}]}}
    end
  end

  @doc """
  Handles messages from the TelephoneChannel and other processes.
  """
  @impl WebSock

  # Backend WebSocket connected successfully
  def handle_info(
        {:ws_connected, connection_id, _response},
        %{connection_id: connection_id} = state
      ) do
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

    {:ok, %{state | buffer: []}}
  end

  # Frame from backend (via telephone)
  def handle_info(
        {:ws_frame, connection_id, opcode, data},
        %{connection_id: connection_id} = state
      ) do
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
  def handle_info(_msg, state) do
    {:ok, state}
  end

  @doc """
  Called when the WebSocket connection is terminated.
  """
  @impl WebSock
  def terminate(_reason, state) do
    # Unregister from registry
    WebSocketProxyRegistry.unregister(state.connection_id)

    # Notify telephone that client disconnected (if we were connected)
    if state.connected do
      send(state.telephone_pid, {:ws_close, state.connection_id, 1000, "Client disconnected"})
    end

    :telemetry.execute(
      [:plugboard, :websocket_proxy, :disconnect],
      %{count: 1},
      %{connection_id: state.connection_id, path_id: state.path_id}
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
