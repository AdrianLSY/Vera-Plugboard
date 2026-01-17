defmodule Plugboard.Repo.Migrations.UpgradeTokenHashSecurity do
  @moduledoc """
  Upgrades token and API key storage to use Argon2 hashing.

  This is a BREAKING CHANGE that invalidates all existing tokens and API keys.
  After this migration:
  - All telephone tokens will be revoked
  - All service account API keys will be revoked
  - Users must generate new tokens/keys

  The token_hash and api_key_hash columns are expanded to accommodate
  Argon2 hashes which are longer than SHA256 hashes.
  """
  use Ecto.Migration

  def up do
    # Revoke all existing tokens (clean break for security upgrade)
    # This is intentional - the new hashing algorithm means old tokens
    # cannot be verified anyway
    execute """
    UPDATE telephone_tokens 
    SET revoked_at = NOW() 
    WHERE revoked_at IS NULL
    """

    execute """
    UPDATE service_accounts 
    SET revoked_at = NOW() 
    WHERE revoked_at IS NULL
    """

    # Expand token_hash column to accommodate Argon2 hashes (~100 chars)
    alter table(:telephone_tokens) do
      modify :token_hash, :string, size: 200
    end

    # Expand api_key_hash column to accommodate Argon2 hashes (~100 chars)
    alter table(:service_accounts) do
      modify :api_key_hash, :string, size: 200
    end
  end

  def down do
    # Note: Cannot restore revoked tokens - this is a one-way migration
    # for security purposes

    # Restore original column sizes
    alter table(:telephone_tokens) do
      modify :token_hash, :string, size: 64
    end

    alter table(:service_accounts) do
      modify :api_key_hash, :string, size: 64
    end
  end
end
