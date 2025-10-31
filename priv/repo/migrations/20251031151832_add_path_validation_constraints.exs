defmodule Plugboard.Repo.Migrations.AddPathValidationConstraints do
  use Ecto.Migration

  def up do
    # Add CHECK constraints to enforce path validation at database level
    # This provides defense-in-depth beyond application-level validation

    execute """
    ALTER TABLE paths
    ADD CONSTRAINT path_no_slashes CHECK (path !~ '/');
    """

    execute """
    ALTER TABLE paths
    ADD CONSTRAINT path_valid_chars CHECK (path ~ '^[a-zA-Z0-9_\\-\\.]+$');
    """

    execute """
    ALTER TABLE paths
    ADD CONSTRAINT path_length CHECK (char_length(path) BETWEEN 1 AND 255);
    """

    # Add index on parent_id for efficient cascade operations
    create index(:paths, [:parent_id], name: :idx_paths_parent_id)
  end

  def down do
    # Drop index first
    drop index(:paths, [:parent_id], name: :idx_paths_parent_id)

    # Drop CHECK constraints
    execute "ALTER TABLE paths DROP CONSTRAINT IF EXISTS path_length;"
    execute "ALTER TABLE paths DROP CONSTRAINT IF EXISTS path_valid_chars;"
    execute "ALTER TABLE paths DROP CONSTRAINT IF EXISTS path_no_slashes;"
  end
end
