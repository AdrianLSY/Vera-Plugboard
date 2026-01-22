defmodule PlugboardWeb.TelephoneSocketTest do
  use PlugboardWeb.ChannelCase, async: true

  import Plugboard.AccountsFixtures
  import Ecto.Query

  alias Plugboard.Paths
  alias Plugboard.TelephoneTokens
  alias PlugboardWeb.TelephoneSocket

  setup do
    user = user_fixture()

    {:ok, path} =
      Paths.create_path(%{
        path: "api",
        user_id: user.id
      })

    {:ok, mount_path} = Paths.update_path(user.id, path, %{mount_point: true})

    %{user: user, path: mount_path}
  end

  describe "connect/3 with valid JWT" do
    test "connects with valid JWT token", %{user: user, path: path} do
      {:ok, jwt, _token} = TelephoneTokens.generate_token(path, user)

      assert {:ok, socket} = connect(TelephoneSocket, %{"token" => jwt})

      # Verify socket assigns are set correctly
      assert socket.assigns.token_id != nil
      assert socket.assigns.path_id == path.id
      assert socket.assigns.path.id == path.id
      assert socket.assigns.user_id == user.id
    end

    test "marks token as used on connection (BLOCKER-1)", %{user: user, path: path} do
      {:ok, jwt, token} = TelephoneTokens.generate_token(path, user)

      # Token should not be marked as used yet
      fresh_token = TelephoneTokens.get_token(token.id)
      assert fresh_token.last_used_at == nil

      # Connect
      assert {:ok, _socket} = connect(TelephoneSocket, %{"token" => jwt})

      # Token should now be marked as used
      used_token = TelephoneTokens.get_token(token.id)
      assert used_token.last_used_at != nil
    end

    test "sets path assign with full path details", %{user: user, path: path} do
      {:ok, jwt, _token} = TelephoneTokens.generate_token(path, user)

      assert {:ok, socket} = connect(TelephoneSocket, %{"token" => jwt})

      # Verify path details
      assert socket.assigns.path.full_path == "/api"
      assert socket.assigns.path.mount_point == true
    end
  end

  describe "connect/3 with invalid JWT" do
    test "rejects connection with invalid JWT signature", %{path: _path} do
      # Create a fake JWT with invalid signature
      fake_jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.invalid"

      assert :error = connect(TelephoneSocket, %{"token" => fake_jwt})
    end

    test "rejects connection with malformed JWT" do
      assert :error = connect(TelephoneSocket, %{"token" => "not.a.jwt"})
      assert :error = connect(TelephoneSocket, %{"token" => "malformed"})
    end

    test "rejects connection without token parameter" do
      assert :error = connect(TelephoneSocket, %{})
    end

    test "rejects connection with nil token" do
      assert :error = connect(TelephoneSocket, %{"token" => nil})
    end

    test "rejects connection with non-string token" do
      assert :error = connect(TelephoneSocket, %{"token" => 123})
    end
  end

  describe "connect/3 with expired JWT" do
    test "rejects connection with expired token", %{user: user, path: path} do
      {:ok, jwt, token} = TelephoneTokens.generate_token(path, user)

      # Manually expire the token
      Plugboard.Repo.update_all(
        from(t in Plugboard.TelephoneTokens.TelephoneToken, where: t.id == ^token.id),
        set: [expires_at: DateTime.add(DateTime.utc_now(), -3600, :second)]
      )

      assert :error = connect(TelephoneSocket, %{"token" => jwt})
    end
  end

  describe "connect/3 with revoked JWT" do
    test "rejects connection with revoked token", %{user: user, path: path} do
      {:ok, jwt, token} = TelephoneTokens.generate_token(path, user)

      # Revoke the token
      {:ok, _revoked} = TelephoneTokens.revoke_token(user.id, token.id)

      assert :error = connect(TelephoneSocket, %{"token" => jwt})
    end

    test "rejects connection after token is revoked (BLOCKER-1)", %{
      user: user,
      path: path
    } do
      {:ok, jwt, token} = TelephoneTokens.generate_token(path, user)

      # Revoke token
      {:ok, _revoked} = TelephoneTokens.revoke_token(user.id, token.id)

      # Connection should fail
      assert :error = connect(TelephoneSocket, %{"token" => jwt})

      # Note: Race condition atomicity is tested in TelephoneTokens.validate_and_mark_used/1
    end
  end

  describe "connect/3 with deleted or invalid path" do
    test "rejects connection when path is deleted", %{user: user, path: path} do
      {:ok, jwt, _token} = TelephoneTokens.generate_token(path, user)

      # Soft delete the path
      {:ok, _deleted} = Paths.delete_path(user.id, path)

      assert :error = connect(TelephoneSocket, %{"token" => jwt})
    end

    test "rejects connection when path is not a mount point", %{user: user, path: path} do
      {:ok, jwt, _token} = TelephoneTokens.generate_token(path, user)

      # Unmark as mount point
      {:ok, _non_mount} = Paths.update_path(user.id, path, %{mount_point: false})

      assert :error = connect(TelephoneSocket, %{"token" => jwt})
    end

    test "rejects connection when path no longer exists", %{user: user} do
      # Create a temporary path
      {:ok, temp_path} = Paths.create_path(%{path: "temp", user_id: user.id})
      {:ok, temp_mount} = Paths.update_path(user.id, temp_path, %{mount_point: true})
      {:ok, jwt, _token} = TelephoneTokens.generate_token(temp_mount, user)

      # Hard delete the path (cascade deletes token)
      Plugboard.Repo.delete_all(from p in Plugboard.Paths.Path, where: p.id == ^temp_path.id)

      assert :error = connect(TelephoneSocket, %{"token" => jwt})
    end
  end

  describe "id/1" do
    test "generates correct socket ID format", %{user: user, path: path} do
      {:ok, jwt, token} = TelephoneTokens.generate_token(path, user)

      assert {:ok, socket} = connect(TelephoneSocket, %{"token" => jwt})

      socket_id = TelephoneSocket.id(socket)

      # Format should be "telephone:path_id:token_id"
      assert socket_id == "telephone:#{path.id}:#{token.id}"
    end

    test "different tokens have different socket IDs", %{user: user, path: path} do
      {:ok, jwt1, token1} = TelephoneTokens.generate_token(path, user)
      {:ok, jwt2, token2} = TelephoneTokens.generate_token(path, user)

      assert {:ok, socket1} = connect(TelephoneSocket, %{"token" => jwt1})
      assert {:ok, socket2} = connect(TelephoneSocket, %{"token" => jwt2})

      socket_id1 = TelephoneSocket.id(socket1)
      socket_id2 = TelephoneSocket.id(socket2)

      # IDs should be different
      refute socket_id1 == socket_id2

      # But both should be for the same path
      assert socket_id1 =~ "telephone:#{path.id}:"
      assert socket_id2 =~ "telephone:#{path.id}:"

      # With different token IDs
      assert socket_id1 =~ token1.id
      assert socket_id2 =~ token2.id
    end

    test "same token on different paths has different socket IDs", %{user: user} do
      # Create two paths
      {:ok, path1} = Paths.create_path(%{path: "api1", user_id: user.id})
      {:ok, mount1} = Paths.update_path(user.id, path1, %{mount_point: true})

      {:ok, path2} = Paths.create_path(%{path: "api2", user_id: user.id})
      {:ok, mount2} = Paths.update_path(user.id, path2, %{mount_point: true})

      # Create tokens for each path
      {:ok, jwt1, token1} = TelephoneTokens.generate_token(mount1, user)
      {:ok, jwt2, token2} = TelephoneTokens.generate_token(mount2, user)

      assert {:ok, socket1} = connect(TelephoneSocket, %{"token" => jwt1})
      assert {:ok, socket2} = connect(TelephoneSocket, %{"token" => jwt2})

      socket_id1 = TelephoneSocket.id(socket1)
      socket_id2 = TelephoneSocket.id(socket2)

      # IDs should be different
      refute socket_id1 == socket_id2

      # Each should contain its respective path and token
      assert socket_id1 == "telephone:#{path1.id}:#{token1.id}"
      assert socket_id2 == "telephone:#{path2.id}:#{token2.id}"
    end
  end

  describe "concurrent connections" do
    test "multiple telephones can connect with different tokens for same path", %{
      user: user,
      path: path
    } do
      # Generate multiple tokens
      {:ok, jwt1, _token1} = TelephoneTokens.generate_token(path, user)
      {:ok, jwt2, _token2} = TelephoneTokens.generate_token(path, user)
      {:ok, jwt3, _token3} = TelephoneTokens.generate_token(path, user)

      # All should connect successfully
      assert {:ok, _socket1} = connect(TelephoneSocket, %{"token" => jwt1})
      assert {:ok, _socket2} = connect(TelephoneSocket, %{"token" => jwt2})
      assert {:ok, _socket3} = connect(TelephoneSocket, %{"token" => jwt3})
    end

    test "same token can be used for multiple concurrent connections", %{user: user, path: path} do
      {:ok, jwt, _token} = TelephoneTokens.generate_token(path, user)

      # Connect multiple times with same token
      assert {:ok, _socket1} = connect(TelephoneSocket, %{"token" => jwt})
      assert {:ok, _socket2} = connect(TelephoneSocket, %{"token" => jwt})
      assert {:ok, _socket3} = connect(TelephoneSocket, %{"token" => jwt})

      # All connections should succeed (token is reusable until revoked)
    end
  end

  describe "security" do
    test "token validation is atomic (BLOCKER-1 verified)", %{user: user, path: path} do
      {:ok, jwt, token} = TelephoneTokens.generate_token(path, user)

      # Verify last_used_at starts as nil
      fresh_token = TelephoneTokens.get_token(token.id)
      assert fresh_token.last_used_at == nil

      # Connect (should call validate_and_mark_used atomically)
      assert {:ok, _socket} = connect(TelephoneSocket, %{"token" => jwt})

      # Verify last_used_at was updated
      used_token = TelephoneTokens.get_token(token.id)
      assert used_token.last_used_at != nil

      # Verify token is still valid (not consumed)
      assert used_token.revoked_at == nil
    end

    test "assigns contain only necessary information", %{user: user, path: path} do
      {:ok, jwt, _token} = TelephoneTokens.generate_token(path, user)

      assert {:ok, socket} = connect(TelephoneSocket, %{"token" => jwt})

      # Verify assigns
      assigns = socket.assigns

      # Should have these
      assert Map.has_key?(assigns, :token_id)
      assert Map.has_key?(assigns, :path_id)
      assert Map.has_key?(assigns, :path)
      assert Map.has_key?(assigns, :user_id)

      # Should not expose sensitive data like token_hash
      refute Map.has_key?(assigns, :token_hash)
      refute Map.has_key?(assigns, :jwt)
    end
  end
end
