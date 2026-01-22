defmodule Plugboard.WebSocketProxyRegistryTest do
  use ExUnit.Case, async: false

  alias Plugboard.WebSocketProxyRegistry

  # Need to ensure the registry is started for tests
  # Since it's part of the application supervision tree, it should already be running

  setup do
    # Clean up any existing registrations before each test
    # by unregistering all connections
    WebSocketProxyRegistry.list_all()
    |> Enum.each(fn %{connection_id: conn_id} ->
      WebSocketProxyRegistry.unregister(conn_id)
    end)

    :ok
  end

  describe "register/4" do
    test "successfully registers a new connection" do
      connection_id = Ecto.UUID.generate()
      handler_pid = self()
      path_id = Ecto.UUID.generate()
      telephone_pid = spawn(fn -> Process.sleep(:infinity) end)

      assert :ok =
               WebSocketProxyRegistry.register(connection_id, handler_pid, path_id, telephone_pid)

      # Verify it's registered
      assert {:ok, info} = WebSocketProxyRegistry.lookup(connection_id)
      assert info.handler_pid == handler_pid
      assert info.path_id == path_id
      assert info.telephone_pid == telephone_pid
      assert is_integer(info.connected_at)
    end

    test "returns error when registering duplicate connection_id" do
      connection_id = Ecto.UUID.generate()
      handler_pid = self()
      path_id = Ecto.UUID.generate()
      telephone_pid = spawn(fn -> Process.sleep(:infinity) end)

      assert :ok =
               WebSocketProxyRegistry.register(connection_id, handler_pid, path_id, telephone_pid)

      assert {:error, :already_registered} =
               WebSocketProxyRegistry.register(connection_id, handler_pid, path_id, telephone_pid)
    end

    test "can register multiple connections with different IDs" do
      path_id = Ecto.UUID.generate()
      telephone_pid = spawn(fn -> Process.sleep(:infinity) end)

      conn_id_1 = Ecto.UUID.generate()
      conn_id_2 = Ecto.UUID.generate()
      conn_id_3 = Ecto.UUID.generate()

      assert :ok = WebSocketProxyRegistry.register(conn_id_1, self(), path_id, telephone_pid)
      assert :ok = WebSocketProxyRegistry.register(conn_id_2, self(), path_id, telephone_pid)
      assert :ok = WebSocketProxyRegistry.register(conn_id_3, self(), path_id, telephone_pid)

      assert {:ok, _} = WebSocketProxyRegistry.lookup(conn_id_1)
      assert {:ok, _} = WebSocketProxyRegistry.lookup(conn_id_2)
      assert {:ok, _} = WebSocketProxyRegistry.lookup(conn_id_3)
    end
  end

  describe "lookup/1" do
    test "returns connection info when found" do
      connection_id = Ecto.UUID.generate()
      handler_pid = self()
      path_id = Ecto.UUID.generate()
      telephone_pid = spawn(fn -> Process.sleep(:infinity) end)

      :ok = WebSocketProxyRegistry.register(connection_id, handler_pid, path_id, telephone_pid)

      assert {:ok, info} = WebSocketProxyRegistry.lookup(connection_id)
      assert info.handler_pid == handler_pid
      assert info.path_id == path_id
      assert info.telephone_pid == telephone_pid
      assert is_integer(info.connected_at)
    end

    test "returns error when not found" do
      non_existent_id = Ecto.UUID.generate()
      assert {:error, :not_found} = WebSocketProxyRegistry.lookup(non_existent_id)
    end
  end

  describe "unregister/1" do
    test "removes an existing connection" do
      connection_id = Ecto.UUID.generate()
      handler_pid = self()
      path_id = Ecto.UUID.generate()
      telephone_pid = spawn(fn -> Process.sleep(:infinity) end)

      :ok = WebSocketProxyRegistry.register(connection_id, handler_pid, path_id, telephone_pid)
      assert {:ok, _} = WebSocketProxyRegistry.lookup(connection_id)

      assert :ok = WebSocketProxyRegistry.unregister(connection_id)
      assert {:error, :not_found} = WebSocketProxyRegistry.lookup(connection_id)
    end

    test "returns ok for non-existent connection (idempotent)" do
      non_existent_id = Ecto.UUID.generate()
      assert :ok = WebSocketProxyRegistry.unregister(non_existent_id)
    end

    test "can unregister multiple times without error" do
      connection_id = Ecto.UUID.generate()
      handler_pid = self()
      path_id = Ecto.UUID.generate()
      telephone_pid = spawn(fn -> Process.sleep(:infinity) end)

      :ok = WebSocketProxyRegistry.register(connection_id, handler_pid, path_id, telephone_pid)

      assert :ok = WebSocketProxyRegistry.unregister(connection_id)
      assert :ok = WebSocketProxyRegistry.unregister(connection_id)
      assert :ok = WebSocketProxyRegistry.unregister(connection_id)
    end
  end

  describe "count_for_path/1" do
    test "returns zero for path with no connections" do
      path_id = Ecto.UUID.generate()
      assert 0 == WebSocketProxyRegistry.count_for_path(path_id)
    end

    test "returns correct count for path with connections" do
      path_id = Ecto.UUID.generate()
      telephone_pid = spawn(fn -> Process.sleep(:infinity) end)

      # Register 3 connections for the same path
      for _ <- 1..3 do
        conn_id = Ecto.UUID.generate()
        :ok = WebSocketProxyRegistry.register(conn_id, self(), path_id, telephone_pid)
      end

      assert 3 == WebSocketProxyRegistry.count_for_path(path_id)
    end

    test "counts only connections for specified path" do
      path_id_1 = Ecto.UUID.generate()
      path_id_2 = Ecto.UUID.generate()
      telephone_pid = spawn(fn -> Process.sleep(:infinity) end)

      # 2 connections for path 1
      for _ <- 1..2 do
        conn_id = Ecto.UUID.generate()
        :ok = WebSocketProxyRegistry.register(conn_id, self(), path_id_1, telephone_pid)
      end

      # 3 connections for path 2
      for _ <- 1..3 do
        conn_id = Ecto.UUID.generate()
        :ok = WebSocketProxyRegistry.register(conn_id, self(), path_id_2, telephone_pid)
      end

      assert 2 == WebSocketProxyRegistry.count_for_path(path_id_1)
      assert 3 == WebSocketProxyRegistry.count_for_path(path_id_2)
    end

    test "decrements count when connection is unregistered" do
      path_id = Ecto.UUID.generate()
      telephone_pid = spawn(fn -> Process.sleep(:infinity) end)

      conn_ids =
        for _ <- 1..3 do
          conn_id = Ecto.UUID.generate()
          :ok = WebSocketProxyRegistry.register(conn_id, self(), path_id, telephone_pid)
          conn_id
        end

      assert 3 == WebSocketProxyRegistry.count_for_path(path_id)

      WebSocketProxyRegistry.unregister(hd(conn_ids))
      assert 2 == WebSocketProxyRegistry.count_for_path(path_id)
    end
  end

  describe "count_all/0" do
    test "returns zero when no connections" do
      assert 0 == WebSocketProxyRegistry.count_all()
    end

    test "returns total count of all connections" do
      path_id_1 = Ecto.UUID.generate()
      path_id_2 = Ecto.UUID.generate()
      telephone_pid = spawn(fn -> Process.sleep(:infinity) end)

      # 2 connections for path 1
      for _ <- 1..2 do
        conn_id = Ecto.UUID.generate()
        :ok = WebSocketProxyRegistry.register(conn_id, self(), path_id_1, telephone_pid)
      end

      # 3 connections for path 2
      for _ <- 1..3 do
        conn_id = Ecto.UUID.generate()
        :ok = WebSocketProxyRegistry.register(conn_id, self(), path_id_2, telephone_pid)
      end

      assert 5 == WebSocketProxyRegistry.count_all()
    end
  end

  describe "list_all/0" do
    test "returns empty list when no connections" do
      assert [] == WebSocketProxyRegistry.list_all()
    end

    test "returns all registered connections" do
      path_id = Ecto.UUID.generate()
      telephone_pid = spawn(fn -> Process.sleep(:infinity) end)

      conn_ids =
        for _ <- 1..3 do
          conn_id = Ecto.UUID.generate()
          :ok = WebSocketProxyRegistry.register(conn_id, self(), path_id, telephone_pid)
          conn_id
        end

      all = WebSocketProxyRegistry.list_all()
      assert length(all) == 3

      returned_conn_ids = Enum.map(all, & &1.connection_id)
      assert Enum.sort(returned_conn_ids) == Enum.sort(conn_ids)
    end

    test "returns correct structure for each connection" do
      connection_id = Ecto.UUID.generate()
      handler_pid = self()
      path_id = Ecto.UUID.generate()
      telephone_pid = spawn(fn -> Process.sleep(:infinity) end)

      :ok = WebSocketProxyRegistry.register(connection_id, handler_pid, path_id, telephone_pid)

      [conn] = WebSocketProxyRegistry.list_all()

      assert conn.connection_id == connection_id
      assert conn.handler_pid == handler_pid
      assert conn.path_id == path_id
      assert conn.telephone_pid == telephone_pid
      assert is_integer(conn.connected_at)
    end
  end

  describe "process monitor cleanup" do
    test "unregisters connection when handler process dies" do
      connection_id = Ecto.UUID.generate()
      path_id = Ecto.UUID.generate()
      telephone_pid = spawn(fn -> Process.sleep(:infinity) end)

      # Spawn a handler process that we can kill
      handler_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      :ok = WebSocketProxyRegistry.register(connection_id, handler_pid, path_id, telephone_pid)
      assert {:ok, _} = WebSocketProxyRegistry.lookup(connection_id)

      # Kill the handler process
      Process.exit(handler_pid, :kill)

      # Give the registry time to process the DOWN message
      Process.sleep(50)

      # Connection should be unregistered
      assert {:error, :not_found} = WebSocketProxyRegistry.lookup(connection_id)
    end

    test "only unregisters the connection belonging to the dead process" do
      path_id = Ecto.UUID.generate()
      telephone_pid = spawn(fn -> Process.sleep(:infinity) end)

      # Register connection with a process we'll kill
      conn_id_1 = Ecto.UUID.generate()

      handler_1 =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      :ok = WebSocketProxyRegistry.register(conn_id_1, handler_1, path_id, telephone_pid)

      # Register another connection with a different process
      conn_id_2 = Ecto.UUID.generate()
      handler_2 = spawn(fn -> Process.sleep(:infinity) end)
      :ok = WebSocketProxyRegistry.register(conn_id_2, handler_2, path_id, telephone_pid)

      # Kill only the first handler
      Process.exit(handler_1, :kill)
      Process.sleep(50)

      # First connection should be unregistered, second should remain
      assert {:error, :not_found} = WebSocketProxyRegistry.lookup(conn_id_1)
      assert {:ok, _} = WebSocketProxyRegistry.lookup(conn_id_2)
    end
  end
end
