defmodule Plugboard.Repo.Migrations.RemoveObsoleteUserColumnsFromPaths do
  use Ecto.Migration

  def up do
    # Remove obsolete user ownership columns from paths table if they exist
    # These have been replaced by the user_paths junction table which supports
    # multiple users per path with different roles (owner, maintainer, viewer)
    # Only remove if columns exist (they may not exist in fresh test databases)
    execute """
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'paths' AND column_name = 'account_id'
      ) THEN
        ALTER TABLE paths DROP COLUMN account_id;
      END IF;

      IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'paths' AND column_name = 'created_by_user_id'
      ) THEN
        ALTER TABLE paths DROP COLUMN created_by_user_id;
      END IF;
    END $$;
    """
  end

  def down do
    # Re-add the columns if rolling back
    # Note: This will lose the user association data!
    # In production, you'd want to migrate data from user_paths back to these columns
    alter table(:paths) do
      add :account_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :created_by_user_id, references(:users, type: :binary_id, on_delete: :delete_all),
        null: false
    end
  end
end
