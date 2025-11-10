defmodule Plugboard.TelephoneTokensTest do
  use Plugboard.DataCase, async: true

  @moduletag :capture_log

  import Plugboard.AccountsFixtures

  alias Plugboard.TelephoneTokens
  alias Plugboard.TelephoneTokens.TelephoneToken
  alias Plugboard.Paths
  alias Plugboard.Repo

  describe "generate_token/3" do
    setup do
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "api",
          user_id: user.id
        })

      {:ok, mount_path} = Paths.update_path(path, %{mount_point: true})

      %{user: user, path: mount_path}
    end

    test "generates valid JWT token for mount point", %{user: user, path: path} do
      assert {:ok, jwt, token} = TelephoneTokens.generate_token(path, user)

      # JWT should be a string
      assert is_binary(jwt)
      assert String.length(jwt) > 50

      # Token record should be created
      assert %TelephoneToken{} = token
      assert token.path_id == path.id
      assert token.user_id == user.id
      assert token.token_hash != nil
      assert token.expires_at != nil
      assert token.revoked_at == nil
      assert token.last_used_at == nil
    end

    test "token includes correct JWT claims", %{user: user, path: path} do
      assert {:ok, jwt, token} = TelephoneTokens.generate_token(path, user)

      # Verify JWT structure by validating it
      assert {:ok, %{token: ^token, path: ^path, user_id: user_id}} =
               TelephoneTokens.validate_jwt(jwt)

      assert user_id == user.id
    end

    test "generates token with custom description", %{user: user, path: path} do
      name = "Production Server"
      description = "Production API server"

      assert {:ok, _jwt, token} = TelephoneTokens.generate_token(path, user, name, description)
      assert token.name == name
      assert token.description == description
    end

    test "generates token with nil description", %{user: user, path: path} do
      assert {:ok, _jwt, token} = TelephoneTokens.generate_token(path, user, nil, nil)
      assert token.name == nil
      assert token.description == nil
    end

    test "token expires according to config", %{user: user, path: path} do
      # Get configured expiry
      expiry_seconds = Application.get_env(:plugboard, :telephone)[:token_expiry] || 3600

      assert {:ok, _jwt, token} = TelephoneTokens.generate_token(path, user)

      # Check expiry is approximately correct (within 5 seconds tolerance)
      expected_expiry = DateTime.utc_now() |> DateTime.add(expiry_seconds, :second)
      diff = DateTime.diff(token.expires_at, expected_expiry, :second)
      assert abs(diff) <= 5
    end

    test "stores hashed token, not plaintext", %{user: user, path: path} do
      assert {:ok, jwt, token} = TelephoneTokens.generate_token(path, user)

      # Token hash should be hex-encoded SHA256 (64 characters)
      assert String.length(token.token_hash) == 64
      assert String.match?(token.token_hash, ~r/^[0-9a-f]+$/)

      # Token hash should not match the JWT
      refute token.token_hash == jwt
    end

    test "rejects non-mount point paths", %{user: user, path: path} do
      # Unmark as mount point
      {:ok, non_mount} = Paths.update_path(path, %{mount_point: false})

      assert {:error, "Path must be a mount point"} =
               TelephoneTokens.generate_token(non_mount, user)
    end

    test "rejects deleted paths", %{user: user, path: path} do
      # Soft delete the path
      {:ok, deleted_path} = Paths.delete_path(path)

      assert {:error, "Path is deleted"} = TelephoneTokens.generate_token(deleted_path, user)
    end

    test "multiple tokens can exist for same path", %{user: user, path: path} do
      assert {:ok, jwt1, token1} = TelephoneTokens.generate_token(path, user, "Token 1")
      assert {:ok, jwt2, token2} = TelephoneTokens.generate_token(path, user, "Token 2")

      assert token1.id != token2.id
      assert jwt1 != jwt2
      assert token1.token_hash != token2.token_hash
    end
  end

  describe "validate_jwt/1" do
    setup do
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "api",
          user_id: user.id
        })

      {:ok, mount_path} = Paths.update_path(path, %{mount_point: true})
      {:ok, jwt, token} = TelephoneTokens.generate_token(mount_path, user)

      %{user: user, path: mount_path, jwt: jwt, token: token}
    end

    test "validates correct JWT token", %{jwt: jwt, token: token, path: path, user: user} do
      assert {:ok, %{token: validated_token, path: validated_path, user_id: user_id}} =
               TelephoneTokens.validate_jwt(jwt)

      assert validated_token.id == token.id
      assert validated_path.id == path.id
      assert user_id == user.id
    end

    test "rejects invalid JWT signature" do
      # Create a fake JWT with invalid signature
      fake_jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.invalid"

      assert {:error, :invalid_token} = TelephoneTokens.validate_jwt(fake_jwt)
    end

    test "rejects malformed JWT" do
      assert {:error, :invalid_token} = TelephoneTokens.validate_jwt("not.a.jwt")
      assert {:error, :invalid_token} = TelephoneTokens.validate_jwt("malformed")
    end

    test "rejects non-string input" do
      assert {:error, "Invalid token format"} = TelephoneTokens.validate_jwt(nil)
      assert {:error, "Invalid token format"} = TelephoneTokens.validate_jwt(123)
      assert {:error, "Invalid token format"} = TelephoneTokens.validate_jwt(%{})
    end

    test "rejects expired token", %{path: path, user: user} do
      # Generate token
      {:ok, jwt, token} = TelephoneTokens.generate_token(path, user)

      # Manually set expires_at to the past
      Repo.update_all(
        from(t in TelephoneToken, where: t.id == ^token.id),
        set: [expires_at: DateTime.add(DateTime.utc_now(), -3600, :second)]
      )

      assert {:error, :token_expired} = TelephoneTokens.validate_jwt(jwt)
    end

    test "rejects revoked token", %{jwt: jwt, token: token} do
      # Revoke the token
      {:ok, _revoked} = TelephoneTokens.revoke_token(token.id)

      assert {:error, :token_revoked} = TelephoneTokens.validate_jwt(jwt)
    end

    test "rejects token for deleted path", %{jwt: jwt, path: path} do
      # Soft delete the path
      {:ok, _deleted} = Paths.delete_path(path)

      # When a path is deleted, get_path returns nil, so we get :path_not_found
      assert {:error, :path_not_found} = TelephoneTokens.validate_jwt(jwt)
    end

    test "rejects token for non-mount path", %{jwt: jwt, path: path} do
      # Unmark as mount point
      {:ok, _non_mount} = Paths.update_path(path, %{mount_point: false})

      assert {:error, :path_not_mount} = TelephoneTokens.validate_jwt(jwt)
    end

    test "rejects token for non-existent path", %{user: user} do
      # Create a token then delete the path completely
      {:ok, path} = Paths.create_path(%{path: "temp", user_id: user.id})
      {:ok, mount_path} = Paths.update_path(path, %{mount_point: true})
      {:ok, jwt, _token} = TelephoneTokens.generate_token(mount_path, user)

      # Hard delete from database (bypassing soft delete)
      # This will cascade delete the token due to on_delete: :delete_all
      Repo.delete_all(from p in Plugboard.Paths.Path, where: p.id == ^path.id)

      # Token no longer exists due to cascade delete
      assert {:error, :token_not_found} = TelephoneTokens.validate_jwt(jwt)
    end

    test "rejects token that doesn't exist in database", %{user: user, path: path} do
      # Generate a valid JWT but don't store it in database
      # We need to hash it the same way the code does to ensure proper lookup
      claims = %{
        "sub" => user.id,
        "jti" => Ecto.UUID.generate(),
        "path_id" => path.id,
        "iat" => DateTime.utc_now() |> DateTime.to_unix(),
        "exp" => DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_unix()
      }

      secret = Application.get_env(:plugboard, PlugboardWeb.Endpoint)[:secret_key_base]
      signer = Joken.Signer.create("HS256", secret)
      jwt = Joken.generate_and_sign!(%{}, claims, signer)

      # Token is valid JWT but not in database
      assert {:error, :token_not_found} = TelephoneTokens.validate_jwt(jwt)
    end
  end

  describe "validate_and_mark_used/1 (BLOCKER-1: Race Condition Fix)" do
    setup do
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "api",
          user_id: user.id
        })

      {:ok, mount_path} = Paths.update_path(path, %{mount_point: true})
      {:ok, jwt, token} = TelephoneTokens.generate_token(mount_path, user)

      %{user: user, path: mount_path, jwt: jwt, token: token}
    end

    test "validates and marks token as used atomically", %{jwt: jwt, token: token} do
      assert {:ok, %{token: validated_token, path: _path, user_id: _user_id}} =
               TelephoneTokens.validate_and_mark_used(jwt)

      assert validated_token.id == token.id

      # Verify token was marked as used
      updated_token = Repo.get(TelephoneToken, token.id)
      assert updated_token.last_used_at != nil

      # last_used_at should be recent (within 5 seconds)
      diff = DateTime.diff(DateTime.utc_now(), updated_token.last_used_at, :second)
      assert diff <= 5
    end

    test "prevents race condition: token revoked during validation", %{jwt: jwt, token: token} do
      # Simulate race condition: token gets revoked while validation is happening
      # This should fail because validation happens in a transaction

      # Start validation
      task =
        Task.async(fn ->
          # Add small delay to allow revocation to happen
          Process.sleep(50)
          TelephoneTokens.validate_and_mark_used(jwt)
        end)

      # Revoke token immediately
      Process.sleep(10)
      {:ok, _revoked} = TelephoneTokens.revoke_token(token.id)

      # Validation should fail
      result = Task.await(task)
      assert {:error, :token_revoked} = result
    end

    test "concurrent validation attempts on same token", %{jwt: jwt} do
      # Multiple processes try to validate the same token concurrently
      # All should succeed because validation doesn't consume the token

      tasks =
        for _i <- 1..5 do
          Task.async(fn ->
            TelephoneTokens.validate_and_mark_used(jwt)
          end)
        end

      results = Enum.map(tasks, &Task.await/1)

      # All validations should succeed
      assert Enum.all?(results, fn
               {:ok, _} -> true
               _ -> false
             end)
    end

    test "rejects invalid token format" do
      assert {:error, "Invalid token format"} = TelephoneTokens.validate_and_mark_used(nil)
      assert {:error, "Invalid token format"} = TelephoneTokens.validate_and_mark_used(123)
    end

    test "rolls back on validation failure", %{user: user, path: path} do
      # Create a token and immediately revoke it
      {:ok, jwt, token} = TelephoneTokens.generate_token(path, user)
      {:ok, _revoked} = TelephoneTokens.revoke_token(token.id)

      # Attempt to validate and mark as used
      assert {:error, :token_revoked} = TelephoneTokens.validate_and_mark_used(jwt)

      # Verify last_used_at was NOT updated (transaction rolled back)
      updated_token = Repo.get(TelephoneToken, token.id)
      assert updated_token.last_used_at == nil
    end
  end

  describe "revoke_token/1" do
    setup do
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "api",
          user_id: user.id
        })

      {:ok, mount_path} = Paths.update_path(path, %{mount_point: true})
      {:ok, jwt, token} = TelephoneTokens.generate_token(mount_path, user)

      %{user: user, path: mount_path, jwt: jwt, token: token}
    end

    test "revokes an active token", %{token: token} do
      assert {:ok, revoked_token} = TelephoneTokens.revoke_token(token.id)

      assert revoked_token.revoked_at != nil
      assert revoked_token.id == token.id

      # revoked_at should be recent
      diff = DateTime.diff(DateTime.utc_now(), revoked_token.revoked_at, :second)
      assert diff <= 5
    end

    test "revoked token fails validation", %{jwt: jwt, token: token} do
      {:ok, _revoked} = TelephoneTokens.revoke_token(token.id)

      assert {:error, :token_revoked} = TelephoneTokens.validate_jwt(jwt)
    end

    test "returns error for non-existent token" do
      fake_id = Ecto.UUID.generate()
      assert {:error, :not_found} = TelephoneTokens.revoke_token(fake_id)
    end

    test "can revoke already revoked token (idempotent)", %{token: token} do
      # First revocation
      {:ok, revoked1} = TelephoneTokens.revoke_token(token.id)
      assert revoked1.revoked_at != nil

      # Second revocation
      {:ok, revoked2} = TelephoneTokens.revoke_token(token.id)
      assert revoked2.revoked_at != nil

      # Timestamps might differ slightly, but both should be revoked
      assert revoked1.id == revoked2.id
    end
  end

  describe "refresh_token/1" do
    setup do
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "api",
          user_id: user.id
        })

      {:ok, mount_path} = Paths.update_path(path, %{mount_point: true})
      {:ok, jwt, token} = TelephoneTokens.generate_token(mount_path, user)

      %{user: user, path: mount_path, jwt: jwt, token: token}
    end

    test "refreshes valid token with new JWT and expiry", %{token: token, jwt: old_jwt} do
      # Get expiry config
      expiry_seconds = Application.get_env(:plugboard, :telephone)[:token_expiry] || 3600

      assert {:ok, new_jwt, ^expiry_seconds} = TelephoneTokens.refresh_token(token.id)

      # New JWT should be different from old JWT
      refute new_jwt == old_jwt

      # New JWT should be valid
      assert {:ok, %{token: refreshed_token}} = TelephoneTokens.validate_jwt(new_jwt)
      assert refreshed_token.id == token.id

      # Old JWT should no longer be valid (token hash changed)
      assert {:error, :token_not_found} = TelephoneTokens.validate_jwt(old_jwt)

      # Expiry should be updated
      updated_token = Repo.get(TelephoneToken, token.id)
      expected_expiry = DateTime.utc_now() |> DateTime.add(expiry_seconds, :second)
      diff = DateTime.diff(updated_token.expires_at, expected_expiry, :second)
      assert abs(diff) <= 5
    end

    test "returns error for non-existent token" do
      fake_id = Ecto.UUID.generate()
      assert {:error, :not_found} = TelephoneTokens.refresh_token(fake_id)
    end

    test "returns error for revoked token", %{token: token} do
      {:ok, _revoked} = TelephoneTokens.revoke_token(token.id)

      assert {:error, :token_revoked} = TelephoneTokens.refresh_token(token.id)
    end
  end

  describe "mark_token_used/1" do
    setup do
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "api",
          user_id: user.id
        })

      {:ok, mount_path} = Paths.update_path(path, %{mount_point: true})
      {:ok, _jwt, token} = TelephoneTokens.generate_token(mount_path, user)

      %{token: token}
    end

    test "updates last_used_at timestamp", %{token: token} do
      assert token.last_used_at == nil

      assert {:ok, updated_token} = TelephoneTokens.mark_token_used(token.id)
      assert updated_token.last_used_at != nil

      # Timestamp should be recent
      diff = DateTime.diff(DateTime.utc_now(), updated_token.last_used_at, :second)
      assert diff <= 5
    end

    test "can be called multiple times (updates timestamp)", %{token: token} do
      {:ok, first_update} = TelephoneTokens.mark_token_used(token.id)
      first_timestamp = first_update.last_used_at

      Process.sleep(1000)

      {:ok, second_update} = TelephoneTokens.mark_token_used(token.id)
      second_timestamp = second_update.last_used_at

      # Second timestamp should be later
      assert DateTime.compare(second_timestamp, first_timestamp) == :gt
    end

    test "returns error for non-existent token" do
      fake_id = Ecto.UUID.generate()
      assert {:error, :not_found} = TelephoneTokens.mark_token_used(fake_id)
    end
  end

  describe "list_tokens_for_path/1" do
    setup do
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "api",
          user_id: user.id
        })

      {:ok, mount_path} = Paths.update_path(path, %{mount_point: true})

      %{user: user, path: mount_path}
    end

    test "returns all active tokens for a path", %{user: user, path: path} do
      {:ok, _jwt1, token1} = TelephoneTokens.generate_token(path, user, "Token 1")
      {:ok, _jwt2, token2} = TelephoneTokens.generate_token(path, user, "Token 2")

      tokens = TelephoneTokens.list_tokens_for_path(path.id)

      assert length(tokens) == 2
      token_ids = Enum.map(tokens, & &1.id)
      assert token1.id in token_ids
      assert token2.id in token_ids
    end

    test "does not return revoked tokens", %{user: user, path: path} do
      {:ok, _jwt1, token1} = TelephoneTokens.generate_token(path, user, "Active")
      {:ok, _jwt2, token2} = TelephoneTokens.generate_token(path, user, "Will revoke")

      # Revoke second token
      {:ok, _revoked} = TelephoneTokens.revoke_token(token2.id)

      tokens = TelephoneTokens.list_tokens_for_path(path.id)

      assert length(tokens) == 1
      assert hd(tokens).id == token1.id
    end

    @tag :sync
    test "returns tokens ordered by most recent first", %{user: user, path: path} do
      {:ok, _jwt1, token1} = TelephoneTokens.generate_token(path, user, "First")
      Process.sleep(100)
      {:ok, _jwt2, token2} = TelephoneTokens.generate_token(path, user, "Second")
      Process.sleep(100)
      {:ok, _jwt3, token3} = TelephoneTokens.generate_token(path, user, "Third")

      tokens = TelephoneTokens.list_tokens_for_path(path.id)

      # Should be ordered newest first (by inserted_at)
      assert length(tokens) == 3

      # Verify ordering by checking timestamps
      assert DateTime.compare(Enum.at(tokens, 0).inserted_at, Enum.at(tokens, 1).inserted_at) in [
               :gt,
               :eq
             ]

      assert DateTime.compare(Enum.at(tokens, 1).inserted_at, Enum.at(tokens, 2).inserted_at) in [
               :gt,
               :eq
             ]

      # Verify all three tokens are present
      token_ids = Enum.map(tokens, & &1.id)
      assert token1.id in token_ids
      assert token2.id in token_ids
      assert token3.id in token_ids
    end

    test "returns empty list for path with no tokens", %{path: path} do
      tokens = TelephoneTokens.list_tokens_for_path(path.id)
      assert tokens == []
    end
  end

  describe "list_tokens_for_user/1" do
    setup do
      user = user_fixture()
      %{user: user}
    end

    test "returns all active tokens for a user across multiple paths", %{user: user} do
      {:ok, path1} = Paths.create_path(%{path: "api", user_id: user.id})
      {:ok, mount1} = Paths.update_path(path1, %{mount_point: true})

      {:ok, path2} = Paths.create_path(%{path: "web", user_id: user.id})
      {:ok, mount2} = Paths.update_path(path2, %{mount_point: true})

      {:ok, _jwt1, token1} = TelephoneTokens.generate_token(mount1, user)
      {:ok, _jwt2, token2} = TelephoneTokens.generate_token(mount2, user)

      tokens = TelephoneTokens.list_tokens_for_user(user.id)

      assert length(tokens) == 2
      token_ids = Enum.map(tokens, & &1.id)
      assert token1.id in token_ids
      assert token2.id in token_ids

      # Should preload path
      assert Enum.all?(tokens, fn t -> Ecto.assoc_loaded?(t.path) end)
    end

    test "does not return revoked tokens", %{user: user} do
      {:ok, path} = Paths.create_path(%{path: "api", user_id: user.id})
      {:ok, mount} = Paths.update_path(path, %{mount_point: true})

      {:ok, _jwt1, token1} = TelephoneTokens.generate_token(mount, user)
      {:ok, _jwt2, token2} = TelephoneTokens.generate_token(mount, user)

      {:ok, _revoked} = TelephoneTokens.revoke_token(token2.id)

      tokens = TelephoneTokens.list_tokens_for_user(user.id)

      assert length(tokens) == 1
      assert hd(tokens).id == token1.id
    end

    test "returns empty list for user with no tokens", %{user: user} do
      tokens = TelephoneTokens.list_tokens_for_user(user.id)
      assert tokens == []
    end
  end

  describe "delete_expired_tokens/0" do
    setup do
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "api",
          user_id: user.id
        })

      {:ok, mount_path} = Paths.update_path(path, %{mount_point: true})

      %{user: user, path: mount_path}
    end

    test "deletes expired tokens", %{user: user, path: path} do
      # Create some tokens
      {:ok, _jwt1, token1} = TelephoneTokens.generate_token(path, user, "Active")
      {:ok, _jwt2, token2} = TelephoneTokens.generate_token(path, user, "Expired 1")
      {:ok, _jwt3, token3} = TelephoneTokens.generate_token(path, user, "Expired 2")

      # Manually expire tokens 2 and 3
      past_time = DateTime.add(DateTime.utc_now(), -7200, :second)

      Repo.update_all(
        from(t in TelephoneToken, where: t.id in [^token2.id, ^token3.id]),
        set: [expires_at: past_time]
      )

      # Run cleanup
      assert {:ok, 2} = TelephoneTokens.delete_expired_tokens()

      # Verify only active token remains
      remaining = Repo.all(TelephoneToken)
      assert length(remaining) == 1
      assert hd(remaining).id == token1.id
    end

    test "does not delete active tokens", %{user: user, path: path} do
      {:ok, _jwt, _token} = TelephoneTokens.generate_token(path, user)

      assert {:ok, 0} = TelephoneTokens.delete_expired_tokens()

      # Token should still exist
      assert length(Repo.all(TelephoneToken)) == 1
    end

    test "returns count of deleted tokens", %{user: user, path: path} do
      # Create 5 expired tokens
      for i <- 1..5 do
        {:ok, _jwt, token} = TelephoneTokens.generate_token(path, user, "Expired #{i}")

        Repo.update_all(
          from(t in TelephoneToken, where: t.id == ^token.id),
          set: [expires_at: DateTime.add(DateTime.utc_now(), -3600, :second)]
        )
      end

      assert {:ok, 5} = TelephoneTokens.delete_expired_tokens()
    end
  end

  describe "get_token/1" do
    setup do
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "api",
          user_id: user.id
        })

      {:ok, mount_path} = Paths.update_path(path, %{mount_point: true})
      {:ok, _jwt, token} = TelephoneTokens.generate_token(mount_path, user)

      %{token: token}
    end

    test "retrieves token by ID", %{token: token} do
      retrieved = TelephoneTokens.get_token(token.id)

      assert retrieved.id == token.id
      assert retrieved.path_id == token.path_id
      assert retrieved.user_id == token.user_id
    end

    test "returns nil for non-existent token" do
      fake_id = Ecto.UUID.generate()
      assert TelephoneTokens.get_token(fake_id) == nil
    end
  end

  describe "edge cases" do
    setup do
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "edgecase-mount",
          user_id: user.id
        })

      {:ok, path} = Paths.update_path(path, %{mount_point: true})

      %{user: user, path: path}
    end

    test "refresh_token/1 works for token about to expire", %{user: user, path: path} do
      # Generate token
      {:ok, _jwt, token_record} =
        TelephoneTokens.generate_token(path, user, "about-to-expire")

      # Manually update the token to be expiring soon (within 1 second)
      soon = DateTime.add(DateTime.utc_now(), 1, :second) |> DateTime.truncate(:second)

      token_record
      |> Ecto.Changeset.change(expires_at: soon)
      |> Repo.update!()

      # Refresh should still work even though token is about to expire
      assert {:ok, new_jwt, expires_in} = TelephoneTokens.refresh_token(token_record.id)
      assert is_binary(new_jwt)
      assert expires_in > 0
    end

    test "list_tokens_for_path/1 with invalid path_id returns empty list" do
      fake_path_id = Ecto.UUID.generate()
      assert TelephoneTokens.list_tokens_for_path(fake_path_id) == []
    end

    test "validate_jwt/1 handles token with edge case expiry times", %{user: user, path: path} do
      # Generate token
      {:ok, jwt, _token_record} =
        TelephoneTokens.generate_token(path, user, "edge-expiry")

      # Should validate successfully right after creation
      assert {:ok, %{token: _token, path: validated_path, user_id: user_id}} =
               TelephoneTokens.validate_jwt(jwt)

      assert validated_path.id == path.id
      assert user_id == user.id
    end
  end
end
