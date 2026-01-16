defmodule PlugboardWeb.TelephoneChannelWebSocketTest do
  use PlugboardWeb.ChannelCase, async: false

  import Plugboard.AccountsFixtures
  alias PlugboardWeb.TelephoneSocket
  alias Plugboard.Paths
  alias Plugboard.TelephoneTokens

  # Tests for WebSocket proxy message handling in TelephoneChannel

  setup do
    user = user_fixture()

    {:ok, path} =
      Paths.create_path(%{
        path: "ws-api",
        user_id: user.id
      })

    {:ok, mount_path} = Paths.update_path(path, %{mount_point: true})
    {:ok, jwt, token} = TelephoneTokens.generate_token(mount_path, user)

    # Connect socket
    {:ok, socket} = connect(TelephoneSocket, %{"token" => jwt})

    # Join channel
    {:ok, _reply, socket} = join(socket, "telephone:#{mount_path.id}")

    %{socket: socket, user: user, path: mount_path, token: token, jwt: jwt}
  end

  describe "ws_connections initialization" do
    test "socket has empty ws_connections on join", %{socket: socket} do
      assert socket.assigns.ws_connections == %{}
    end
  end

  describe "handle_in ws_connected" do
    test "notifies handler when connection is registered", %{socket: socket} do
      connection_id = Ecto.UUID.generate()
      test_pid = self()

      # First, register the handler via ws_connect
      send(
        socket.channel_pid,
        {:ws_connect, test_pid, connection_id, %{path: "/ws", query_string: "", headers: %{}}}
      )

      # Wait for the push to be processed
      assert_push "ws_connect", _

      # Now push ws_connected event from telephone
      push(socket, "ws_connected", %{
        "connection_id" => connection_id,
        "protocol" => "graphql-ws"
      })

      # Handler should receive the notification
      assert_receive {:ws_connected, ^connection_id,
                      %{"connection_id" => ^connection_id, "protocol" => "graphql-ws"}}
    end

    test "handles unknown connection_id gracefully", %{socket: socket} do
      connection_id = Ecto.UUID.generate()

      # Push ws_connected for unknown connection - should not crash
      push(socket, "ws_connected", %{"connection_id" => connection_id})

      # Give it time to process
      Process.sleep(50)

      # Channel should still be alive
      assert Process.alive?(socket.channel_pid)
    end
  end

  describe "handle_in ws_frame" do
    test "forwards frame to handler", %{socket: socket} do
      connection_id = Ecto.UUID.generate()
      test_pid = self()

      # Register handler first
      send(
        socket.channel_pid,
        {:ws_connect, test_pid, connection_id, %{path: "/ws", query_string: "", headers: %{}}}
      )

      assert_push "ws_connect", _

      # Push ws_frame event
      data = Base.encode64("hello world")

      push(socket, "ws_frame", %{
        "connection_id" => connection_id,
        "opcode" => "text",
        "data" => data
      })

      # Handler should receive the frame
      assert_receive {:ws_frame, ^connection_id, "text", "hello world"}
    end

    test "decodes base64 data", %{socket: socket} do
      connection_id = Ecto.UUID.generate()
      test_pid = self()

      # Register handler
      send(
        socket.channel_pid,
        {:ws_connect, test_pid, connection_id, %{path: "/ws", query_string: "", headers: %{}}}
      )

      assert_push "ws_connect", _

      # Send binary data
      binary_data = <<1, 2, 3, 4, 5>>
      encoded = Base.encode64(binary_data)

      push(socket, "ws_frame", %{
        "connection_id" => connection_id,
        "opcode" => "binary",
        "data" => encoded
      })

      assert_receive {:ws_frame, ^connection_id, "binary", ^binary_data}
    end

    test "handles unknown connection_id gracefully", %{socket: socket} do
      connection_id = Ecto.UUID.generate()

      push(socket, "ws_frame", %{
        "connection_id" => connection_id,
        "opcode" => "text",
        "data" => Base.encode64("test")
      })

      # Give it time to process
      Process.sleep(50)

      # Channel should still be alive
      assert Process.alive?(socket.channel_pid)
    end
  end

  describe "handle_in ws_closed" do
    test "notifies handler and removes from connections", %{socket: socket} do
      connection_id = Ecto.UUID.generate()
      test_pid = self()

      # Register handler first
      send(
        socket.channel_pid,
        {:ws_connect, test_pid, connection_id, %{path: "/ws", query_string: "", headers: %{}}}
      )

      assert_push "ws_connect", _

      push(socket, "ws_closed", %{
        "connection_id" => connection_id,
        "code" => 1000,
        "reason" => "Normal closure"
      })

      # Handler should receive notification
      assert_receive {:ws_closed, ^connection_id, 1000, "Normal closure"}
    end

    test "uses default values when code/reason not provided", %{socket: socket} do
      connection_id = Ecto.UUID.generate()
      test_pid = self()

      # Register handler
      send(
        socket.channel_pid,
        {:ws_connect, test_pid, connection_id, %{path: "/ws", query_string: "", headers: %{}}}
      )

      assert_push "ws_connect", _

      push(socket, "ws_closed", %{"connection_id" => connection_id})

      assert_receive {:ws_closed, ^connection_id, 1000, _reason}
    end
  end

  describe "handle_in ws_error" do
    test "notifies handler and removes from connections", %{socket: socket} do
      connection_id = Ecto.UUID.generate()
      test_pid = self()

      # Register handler first
      send(
        socket.channel_pid,
        {:ws_connect, test_pid, connection_id, %{path: "/ws", query_string: "", headers: %{}}}
      )

      assert_push "ws_connect", _

      push(socket, "ws_error", %{
        "connection_id" => connection_id,
        "reason" => "connection_refused"
      })

      assert_receive {:ws_error, ^connection_id, "connection_refused"}
    end
  end

  describe "handle_info {:ws_connect, ...}" do
    test "stores handler and pushes event to telephone", %{socket: socket} do
      connection_id = Ecto.UUID.generate()
      handler_pid = self()

      params = %{
        path: "/websocket",
        query_string: "token=abc",
        headers: %{"authorization" => "Bearer xyz"}
      }

      # Send ws_connect message to channel
      send(socket.channel_pid, {:ws_connect, handler_pid, connection_id, params})

      # Should push ws_connect event
      assert_push "ws_connect", payload
      assert payload["connection_id"] == connection_id
      assert payload["path"] == "/websocket"
      assert payload["query_string"] == "token=abc"
      assert payload["headers"] == %{"authorization" => "Bearer xyz"}
    end
  end

  describe "handle_info {:ws_frame, ...}" do
    test "pushes frame event to telephone", %{socket: socket} do
      connection_id = Ecto.UUID.generate()

      # Send ws_frame message
      send(socket.channel_pid, {:ws_frame, connection_id, :text, "hello"})

      # Should push ws_frame event with base64 encoded data
      assert_push "ws_frame", payload
      assert payload["connection_id"] == connection_id
      assert payload["opcode"] == "text"
      assert payload["data"] == Base.encode64("hello")
    end

    test "encodes binary data as base64", %{socket: socket} do
      connection_id = Ecto.UUID.generate()
      binary_data = <<1, 2, 3, 4, 5>>

      send(socket.channel_pid, {:ws_frame, connection_id, :binary, binary_data})

      assert_push "ws_frame", payload
      assert payload["opcode"] == "binary"
      assert payload["data"] == Base.encode64(binary_data)
    end
  end

  describe "handle_info {:ws_close, ...}" do
    test "pushes close event to telephone", %{socket: socket} do
      connection_id = Ecto.UUID.generate()

      send(socket.channel_pid, {:ws_close, connection_id, 1000, "Client disconnected"})

      assert_push "ws_close", payload
      assert payload["connection_id"] == connection_id
      assert payload["code"] == 1000
      assert payload["reason"] == "Client disconnected"
    end
  end

  describe "handle_info {:DOWN, ...}" do
    test "cleans up connection when handler dies", %{socket: socket} do
      connection_id = Ecto.UUID.generate()

      # Spawn a handler that we can kill
      handler_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      # Manually add the handler to ws_connections (simulating ws_connect)
      send(
        socket.channel_pid,
        {:ws_connect, handler_pid, connection_id, %{path: "/ws", query_string: "", headers: %{}}}
      )

      # Wait for ws_connect to be processed
      assert_push "ws_connect", _

      # Kill the handler
      Process.exit(handler_pid, :kill)

      # Wait a bit for DOWN message to be processed
      Process.sleep(50)

      # Should push ws_close to telephone
      assert_push "ws_close", payload
      assert payload["connection_id"] == connection_id
      assert payload["code"] == 1001
    end
  end
end
