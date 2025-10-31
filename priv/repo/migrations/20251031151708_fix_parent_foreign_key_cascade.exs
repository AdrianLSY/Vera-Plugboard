defmodule Plugboard.Repo.Migrations.FixParentForeignKeyCascade do
  use Ecto.Migration

  def up do
    # Drop existing foreign key constraint
    execute "ALTER TABLE paths DROP CONSTRAINT IF EXISTS paths_parent_id_fkey"

    # Recreate with ON DELETE RESTRICT
    # Soft-delete cascade is handled by application code, not database
    execute """
    ALTER TABLE paths
    ADD CONSTRAINT paths_parent_id_fkey
    FOREIGN KEY (parent_id)
    REFERENCES paths(id)
    ON DELETE RESTRICT
    """
  end

  def down do
    # Revert to original ON DELETE CASCADE
    execute "ALTER TABLE paths DROP CONSTRAINT IF EXISTS paths_parent_id_fkey"

    execute """
    ALTER TABLE paths
    ADD CONSTRAINT paths_parent_id_fkey
    FOREIGN KEY (parent_id)
    REFERENCES paths(id)
    ON DELETE CASCADE
    """
  end
end
