defmodule Plugboard.Repo.Migrations.CreateServiceAccountsTable do
  use Ecto.Migration

  def change do
    create table(:service_accounts, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :path_id, references(:paths, type: :binary_id, on_delete: :delete_all), null: false

      add :name, :text, null: false
      add :description, :text
      add :api_key_hash, :text, null: false

      add :revoked_at, :utc_datetime
      add :last_used_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    # Unique constraint on active api key hashes
    execute """
            CREATE UNIQUE INDEX service_accounts_unique_api_key
            ON service_accounts (api_key_hash)
            WHERE revoked_at IS NULL
            """,
            "DROP INDEX service_accounts_unique_api_key"

    # Unique constraint on name per user
    create unique_index(:service_accounts, [:user_id, :name],
             name: :service_accounts_unique_name_per_user,
             where: "revoked_at IS NULL"
           )

    # Indexes for efficient lookups
    create index(:service_accounts, [:user_id], name: :idx_service_accounts_user_id)
    create index(:service_accounts, [:path_id], name: :idx_service_accounts_path_id)
  end
end
