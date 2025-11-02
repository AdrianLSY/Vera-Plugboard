defmodule Plugboard.Repo.Migrations.CreateTelephoneTokensTable do
  use Ecto.Migration

  def change do
    create table(:telephone_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :path_id, references(:paths, type: :binary_id, on_delete: :delete_all), null: false
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :token_hash, :text, null: false
      add :description, :text

      add :expires_at, :utc_datetime, null: false
      add :revoked_at, :utc_datetime
      add :last_used_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    # Unique constraint on active token hashes
    execute """
            CREATE UNIQUE INDEX telephone_tokens_unique_hash
            ON telephone_tokens (token_hash)
            WHERE revoked_at IS NULL
            """,
            "DROP INDEX telephone_tokens_unique_hash"

    # Indexes for efficient lookups
    create index(:telephone_tokens, [:path_id], name: :idx_telephone_tokens_path_id)
    create index(:telephone_tokens, [:user_id], name: :idx_telephone_tokens_user_id)
    create index(:telephone_tokens, [:expires_at], name: :idx_telephone_tokens_expires_at)
  end
end
