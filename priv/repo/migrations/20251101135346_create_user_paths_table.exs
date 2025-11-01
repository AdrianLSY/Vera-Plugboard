defmodule Plugboard.Repo.Migrations.CreateUserPathsTable do
  use Ecto.Migration

  def change do
    create table(:user_paths, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :path_id, references(:paths, type: :binary_id, on_delete: :delete_all), null: false

      add :role, :string, null: false

      timestamps(type: :utc_datetime)
    end

    # Unique constraint to prevent duplicate user-path relationships
    create unique_index(:user_paths, [:user_id, :path_id], name: :user_paths_unique_user_path)

    # Indexes for efficient lookups
    create index(:user_paths, [:user_id], name: :idx_user_paths_user_id)
    create index(:user_paths, [:path_id], name: :idx_user_paths_path_id)
    create index(:user_paths, [:role], name: :idx_user_paths_role)

    # CHECK constraint for valid roles
    execute """
            ALTER TABLE user_paths
            ADD CONSTRAINT valid_role CHECK (role IN ('owner', 'maintainer', 'viewer'));
            """,
            "ALTER TABLE user_paths DROP CONSTRAINT valid_role"
  end
end
