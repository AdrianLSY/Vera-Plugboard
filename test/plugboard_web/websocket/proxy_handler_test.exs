defmodule PlugboardWeb.WebSocket.ProxyHandlerTest do
  use ExUnit.Case, async: false

  alias Plugboard.WebSocketProxyRegistry
  alias PlugboardWeb.WebSocket.ProxyHandler

  # Clean up registry between tests
  setup do
    WebSocketProxyRegistry.list_all()
    |> Enum.each(fn %{connection_id: conn_id} ->
      WebSocketProxyRegistry.unregister(conn_id)
    end)

    :ok
  end

  describe "init/1" do
    test "registers connection and sends ws_connect to telephone" do
      connection_id = Ecto.UUID.generate()
      path_id = Ecto.UUID.generate()
      test_pid = self()

      # Spawn a mock telephone that captures messages
      telephone_pid =
        spawn(fn ->
          receive do
            {:ws_connect, handler_pid, ^connection_id, params} ->
              send(test_pid, {:ws_connect_received, handler_pid, params})
          after
            5000 -> :ok
          end

          Process.sleep(:infinity)
        end)

      initial_state = %{
        connection_id: connection_id,
        path_id: path_id,
        telephone_pid: telephone_pid,
        forwarded_path: "/websocket",
        query_string: "token=abc",
        headers: %{"authorization" => "Bearer xyz"},
        subprotocols: ["graphql-ws"]
      }

      # Call init
      assert {:ok, state} = ProxyHandler.init(initial_state)

      # Verify state
      assert state.connection_id == connection_id
      assert state.path_id == path_id
      assert state.telephone_pid == telephone_pid
      assert state.connected == false
      assert state.buffer == []
      assert is_reference(state.connect_timeout_ref)

      # Verify ws_connect was sent
      assert_receive {:ws_connect_received, _handler_pid, params}
      assert params.path == "/websocket"
      assert params.query_string == "token=abc"
      assert params.headers == %{"authorization" => "Bearer xyz"}

      # Verify registered in registry
      assert {:ok, info} = WebSocketProxyRegistry.lookup(connection_id)
      assert info.path_id == path_id
    end
  end

  describe "handle_in/2 - frame handling" do
    test "forwards frame to telephone when connected" do
      test_pid = self()
      connection_id = Ecto.UUID.generate()

      telephone_pid =
        spawn(fn ->
          receive do
            {:ws_frame, ^connection_id, opcode, data} ->
              send(test_pid, {:frame_received, opcode, data})
          after
            5000 -> :ok
          end

          Process.sleep(:infinity)
        end)

      state = %{
        connection_id: connection_id,
        path_id: Ecto.UUID.generate(),
        telephone_pid: telephone_pid,
        connected: true,
        buffer: []
      }

      # Send a text frame
      assert {:ok, ^state} = ProxyHandler.handle_in({"hello", opcode: :text}, state)

      # Verify frame was forwarded
      assert_receive {:frame_received, :text, "hello"}
    end

    test "buffers frame when not yet connected" do
      telephone_pid = spawn(fn -> Process.sleep(:infinity) end)

      state = %{
        connection_id: Ecto.UUID.generate(),
        path_id: Ecto.UUID.generate(),
        telephone_pid: telephone_pid,
        connected: false,
        buffer: []
      }

      # Send a text frame while not connected
      assert {:ok, new_state} = ProxyHandler.handle_in({"hello", opcode: :text}, state)

      # Should be buffered
      assert new_state.buffer == [{:text, "hello"}]
    end

    test "buffers multiple frames in order" do
      telephone_pid = spawn(fn -> Process.sleep(:infinity) end)

      state = %{
        connection_id: Ecto.UUID.generate(),
        path_id: Ecto.UUID.generate(),
        telephone_pid: telephone_pid,
        connected: false,
        buffer: []
      }

      {:ok, state} = ProxyHandler.handle_in({"first", opcode: :text}, state)
      {:ok, state} = ProxyHandler.handle_in({"second", opcode: :text}, state)
      {:ok, state} = ProxyHandler.handle_in({<<1, 2, 3>>, opcode: :binary}, state)

      assert state.buffer == [{:text, "first"}, {:text, "second"}, {:binary, <<1, 2, 3>>}]
    end
  end

  describe "handle_info/2 - ws_connected" do
    test "sets connected to true and flushes buffer" do
      test_pid = self()
      connection_id = Ecto.UUID.generate()

      telephone_pid =
        spawn(fn ->
          receive_loop = fn loop ->
            receive do
              {:ws_frame, ^connection_id, opcode, data} ->
                send(test_pid, {:frame_received, opcode, data})
                loop.(loop)

              _ ->
                loop.(loop)
            after
              5000 -> :ok
            end
          end

          receive_loop.(receive_loop)
        end)

      state = %{
        connection_id: connection_id,
        path_id: Ecto.UUID.generate(),
        telephone_pid: telephone_pid,
        connected: false,
        buffer: [{:text, "buffered1"}, {:text, "buffered2"}],
        connect_timeout_ref: make_ref()
      }

      # Receive ws_connected
      {:ok, new_state} = ProxyHandler.handle_info({:ws_connected, connection_id, %{}}, state)

      assert new_state.connected == true
      assert new_state.buffer == []

      # Verify buffered frames were forwarded
      assert_receive {:frame_received, :text, "buffered1"}
      assert_receive {:frame_received, :text, "buffered2"}
    end

    test "ignores ws_connected for different connection_id" do
      telephone_pid = spawn(fn -> Process.sleep(:infinity) end)
      connection_id = Ecto.UUID.generate()
      other_connection_id = Ecto.UUID.generate()

      state = %{
        connection_id: connection_id,
        path_id: Ecto.UUID.generate(),
        telephone_pid: telephone_pid,
        connected: false,
        buffer: [{:text, "buffered"}],
        connect_timeout_ref: make_ref()
      }

      # Receive ws_connected for different connection
      {:ok, new_state} =
        ProxyHandler.handle_info({:ws_connected, other_connection_id, %{}}, state)

      # State should be unchanged
      assert new_state.connected == false
      assert new_state.buffer == [{:text, "buffered"}]
    end
  end

  describe "handle_info/2 - ws_frame" do
    test "returns frame to send to client" do
      connection_id = Ecto.UUID.generate()

      state = %{
        connection_id: connection_id,
        path_id: Ecto.UUID.generate(),
        telephone_pid: spawn(fn -> Process.sleep(:infinity) end),
        connected: true,
        buffer: []
      }

      # Receive frame from backend
      {:push, frame, ^state} =
        ProxyHandler.handle_info({:ws_frame, connection_id, "text", "hello"}, state)

      assert frame == {:text, "hello"}
    end

    test "handles binary opcode" do
      connection_id = Ecto.UUID.generate()

      state = %{
        connection_id: connection_id,
        path_id: Ecto.UUID.generate(),
        telephone_pid: spawn(fn -> Process.sleep(:infinity) end),
        connected: true,
        buffer: []
      }

      {:push, frame, ^state} =
        ProxyHandler.handle_info({:ws_frame, connection_id, "binary", <<1, 2, 3>>}, state)

      assert frame == {:binary, <<1, 2, 3>>}
    end

    test "handles atom opcode" do
      connection_id = Ecto.UUID.generate()

      state = %{
        connection_id: connection_id,
        path_id: Ecto.UUID.generate(),
        telephone_pid: spawn(fn -> Process.sleep(:infinity) end),
        connected: true,
        buffer: []
      }

      {:push, frame, ^state} =
        ProxyHandler.handle_info({:ws_frame, connection_id, :ping, "ping"}, state)

      assert frame == {:ping, "ping"}
    end
  end

  describe "handle_info/2 - ws_closed" do
    test "returns stop with close code and reason" do
      connection_id = Ecto.UUID.generate()

      state = %{
        connection_id: connection_id,
        path_id: Ecto.UUID.generate(),
        telephone_pid: spawn(fn -> Process.sleep(:infinity) end),
        connected: true,
        buffer: []
      }

      {:stop, :normal, {1000, "Normal closure"}, ^state} =
        ProxyHandler.handle_info({:ws_closed, connection_id, 1000, "Normal closure"}, state)
    end
  end

  describe "handle_info/2 - ws_error" do
    test "returns stop with 1014 bad gateway code" do
      connection_id = Ecto.UUID.generate()

      state = %{
        connection_id: connection_id,
        path_id: Ecto.UUID.generate(),
        telephone_pid: spawn(fn -> Process.sleep(:infinity) end),
        connected: false,
        buffer: []
      }

      {:stop, :normal, {1014, reason}, ^state} =
        ProxyHandler.handle_info({:ws_error, connection_id, "connection_refused"}, state)

      assert reason =~ "connection_refused"
    end
  end

  describe "handle_info/2 - telephone_disconnected" do
    test "returns stop with 1001 going away code" do
      connection_id = Ecto.UUID.generate()

      state = %{
        connection_id: connection_id,
        path_id: Ecto.UUID.generate(),
        telephone_pid: spawn(fn -> Process.sleep(:infinity) end),
        connected: true,
        buffer: []
      }

      {:stop, :normal, {1001, reason}, ^state} =
        ProxyHandler.handle_info({:telephone_disconnected, connection_id}, state)

      assert reason =~ "disconnected"
    end
  end

  describe "handle_info/2 - connect_timeout" do
    test "returns stop with 1014 timeout code" do
      test_pid = self()
      connection_id = Ecto.UUID.generate()

      telephone_pid =
        spawn(fn ->
          receive do
            {:ws_close, ^connection_id, code, reason} ->
              send(test_pid, {:ws_close_received, code, reason})
          after
            5000 -> :ok
          end

          Process.sleep(:infinity)
        end)

      state = %{
        connection_id: connection_id,
        path_id: Ecto.UUID.generate(),
        telephone_pid: telephone_pid,
        connected: false,
        buffer: []
      }

      {:stop, :normal, {1014, reason}, ^state} = ProxyHandler.handle_info(:connect_timeout, state)

      assert reason =~ "timeout"

      # Verify ws_close was sent to telephone
      assert_receive {:ws_close_received, 1014, _}
    end
  end

  describe "terminate/2" do
    test "unregisters from registry" do
      connection_id = Ecto.UUID.generate()
      path_id = Ecto.UUID.generate()
      telephone_pid = spawn(fn -> Process.sleep(:infinity) end)

      # Register the connection
      :ok = WebSocketProxyRegistry.register(connection_id, self(), path_id, telephone_pid)
      assert {:ok, _} = WebSocketProxyRegistry.lookup(connection_id)

      state = %{
        connection_id: connection_id,
        path_id: path_id,
        telephone_pid: telephone_pid,
        connected: true,
        buffer: []
      }

      # Terminate
      assert :ok = ProxyHandler.terminate(:normal, state)

      # Should be unregistered
      assert {:error, :not_found} = WebSocketProxyRegistry.lookup(connection_id)
    end

    test "sends ws_close to telephone when connected" do
      test_pid = self()
      connection_id = Ecto.UUID.generate()

      telephone_pid =
        spawn(fn ->
          receive do
            {:ws_close, ^connection_id, code, reason} ->
              send(test_pid, {:ws_close_received, code, reason})
          after
            5000 -> :ok
          end

          Process.sleep(:infinity)
        end)

      state = %{
        connection_id: connection_id,
        path_id: Ecto.UUID.generate(),
        telephone_pid: telephone_pid,
        connected: true,
        buffer: []
      }

      ProxyHandler.terminate(:normal, state)

      assert_receive {:ws_close_received, 1000, "Client disconnected"}
    end

    test "does not send ws_close when not connected" do
      test_pid = self()
      connection_id = Ecto.UUID.generate()

      telephone_pid =
        spawn(fn ->
          receive do
            {:ws_close, ^connection_id, _code, _reason} ->
              send(test_pid, :ws_close_received)
          after
            200 -> send(test_pid, :no_ws_close)
          end
        end)

      state = %{
        connection_id: connection_id,
        path_id: Ecto.UUID.generate(),
        telephone_pid: telephone_pid,
        connected: false,
        buffer: []
      }

      ProxyHandler.terminate(:normal, state)

      # Give the spawned process time to timeout and send the message
      assert_receive :no_ws_close, 500
    end
  end
end
