defmodule Plugboard.TelephoneTokens.TokenCleanupTest do
  use Plugboard.DataCase, async: false

  import Plugboard.AccountsFixtures

  alias Plugboard.Paths
  alias Plugboard.TelephoneTokens
  alias Plugboard.TelephoneTokens.TokenCleanup

  describe "cleanup_now/0" do
    test "removes expired tokens" do
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "test-cleanup",
          user_id: user.id
        })

      {:ok, mount} = Paths.update_path(user.id, path, %{mount_point: true})

      # Create 3 tokens
      tokens =
        for _i <- 1..3 do
          {:ok, _jwt, token} = TelephoneTokens.generate_token(mount, user)
          token
        end

      # Verify all tokens exist
      assert length(TelephoneTokens.list_tokens_for_path(mount.id)) == 3

      # Manually expire 2 tokens by updating their expires_at
      expired_time = DateTime.add(DateTime.utc_now(), -3600, :second)

      for token <- Enum.take(tokens, 2) do
        Plugboard.Repo.update_all(
          from(t in Plugboard.TelephoneTokens.TelephoneToken, where: t.id == ^token.id),
          set: [expires_at: expired_time]
        )
      end

      # Trigger cleanup
      {:ok, count} = TokenCleanup.cleanup_now()

      # Should have removed at least our 2 expired tokens
      assert count >= 2

      # Verify only 1 token remains for our mount
      remaining_tokens = TelephoneTokens.list_tokens_for_path(mount.id)
      assert length(remaining_tokens) == 1
    end

    test "does not remove non-expired tokens" do
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "test-valid-tokens",
          user_id: user.id
        })

      {:ok, mount} = Paths.update_path(user.id, path, %{mount_point: true})

      # Create 2 valid tokens
      for _i <- 1..2 do
        {:ok, _jwt, _token} = TelephoneTokens.generate_token(mount, user)
      end

      initial_count = length(TelephoneTokens.list_tokens_for_path(mount.id))
      assert initial_count == 2

      # Trigger cleanup
      {:ok, _count} = TokenCleanup.cleanup_now()

      # All tokens should still exist
      final_count = length(TelephoneTokens.list_tokens_for_path(mount.id))
      assert final_count == 2
    end

    @tag :capture_log
    test "handles periodic cleanup message" do
      user = user_fixture()

      {:ok, path} =
        Paths.create_path(%{
          path: "test-periodic-cleanup",
          user_id: user.id
        })

      {:ok, mount} = Paths.update_path(user.id, path, %{mount_point: true})

      # Create an expired token
      {:ok, _jwt, token} = TelephoneTokens.generate_token(mount, user)
      expired_time = DateTime.add(DateTime.utc_now(), -3600, :second)

      Plugboard.Repo.update_all(
        from(t in Plugboard.TelephoneTokens.TelephoneToken, where: t.id == ^token.id),
        set: [expires_at: expired_time]
      )

      # Verify token exists
      assert length(TelephoneTokens.list_tokens_for_path(mount.id)) == 1

      # Get the TokenCleanup process and send cleanup message
      cleanup_pid = Process.whereis(TokenCleanup)
      assert cleanup_pid != nil

      send(cleanup_pid, :cleanup)

      # Wait for async cleanup to complete
      :timer.sleep(200)

      # Verify token was removed
      remaining_tokens = TelephoneTokens.list_tokens_for_path(mount.id)
      assert remaining_tokens == []
    end
  end
end
