defmodule Plugboard.Repo.Migrations.CreatePathsTable do
  use Ecto.Migration

  def up do
    create table(:paths, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :created_by_user_id, references(:users, type: :binary_id, on_delete: :restrict),
        null: false

      add :parent_id, references(:paths, type: :binary_id, on_delete: :delete_all), null: true
      add :path, :text, null: false
      add :full_path, :text, null: false
      add :mount_point, :boolean, default: false, null: false

      timestamps(type: :utc_datetime)
      add :deleted_at, :utc_datetime, null: true
    end

    # Use expression index to handle NULL parent_id properly
    # COALESCE converts NULL to a consistent value for the unique constraint
    execute """
            CREATE UNIQUE INDEX paths_unique_sibling_path
            ON paths (user_id, COALESCE(parent_id::text, ''), path)
            WHERE deleted_at IS NULL
            """,
            "DROP INDEX paths_unique_sibling_path"

    create index(:paths, [:full_path], name: :idx_paths_full_path)
    create index(:paths, [:mount_point, :full_path], name: :idx_paths_mount_point_full_path)
    create index(:paths, [:user_id], name: :idx_paths_user_id)

    # Trigger function to compute full_path from parent hierarchy
    execute """
    CREATE OR REPLACE FUNCTION compute_full_path()
    RETURNS TRIGGER AS $$
    DECLARE
      parent_full_path TEXT;
    BEGIN
      IF NEW.parent_id IS NULL THEN
        -- Root level path
        NEW.full_path := '/' || NEW.path;
      ELSE
        -- Get parent's full_path
        SELECT full_path INTO parent_full_path
        FROM paths
        WHERE id = NEW.parent_id;

        IF parent_full_path IS NULL THEN
          RAISE EXCEPTION 'Parent path not found';
        END IF;

        -- Concatenate parent path with current path
        NEW.full_path := parent_full_path || '/' || NEW.path;
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """

    execute """
    CREATE TRIGGER trigger_compute_full_path
    BEFORE INSERT OR UPDATE OF path, parent_id
    ON paths
    FOR EACH ROW
    EXECUTE FUNCTION compute_full_path();
    """

    # Trigger function to prevent creating a child under a mount point
    execute """
    CREATE OR REPLACE FUNCTION prevent_child_under_mount()
    RETURNS TRIGGER AS $$
    DECLARE
      parent_is_mount BOOLEAN;
    BEGIN
      IF NEW.parent_id IS NOT NULL THEN
        SELECT mount_point INTO parent_is_mount
        FROM paths
        WHERE id = NEW.parent_id
        AND deleted_at IS NULL;

        IF parent_is_mount = TRUE THEN
          RAISE EXCEPTION 'Cannot create child path under a mount point'
            USING ERRCODE = 'check_violation',
                  HINT = 'Mount points are terminal and cannot have children';
        END IF;
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """

    execute """
    CREATE TRIGGER trigger_prevent_child_under_mount
    BEFORE INSERT OR UPDATE OF parent_id
    ON paths
    FOR EACH ROW
    EXECUTE FUNCTION prevent_child_under_mount();
    """

    # Trigger function to prevent marking a path as mount if it has children
    execute """
    CREATE OR REPLACE FUNCTION prevent_mount_when_has_children()
    RETURNS TRIGGER AS $$
    DECLARE
      child_count INTEGER;
    BEGIN
      IF NEW.mount_point = TRUE AND (OLD IS NULL OR OLD.mount_point = FALSE) THEN
        SELECT COUNT(*) INTO child_count
        FROM paths
        WHERE parent_id = NEW.id
        AND deleted_at IS NULL;

        IF child_count > 0 THEN
          RAISE EXCEPTION 'Cannot mark path as mount point when it has children'
            USING ERRCODE = 'check_violation',
                  HINT = 'Remove all children before marking as mount point';
        END IF;
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """

    execute """
    CREATE TRIGGER trigger_prevent_mount_when_has_children
    BEFORE UPDATE OF mount_point
    ON paths
    FOR EACH ROW
    EXECUTE FUNCTION prevent_mount_when_has_children();
    """

    # Trigger to update full_path of all descendants when parent path changes
    execute """
    CREATE OR REPLACE FUNCTION update_descendant_full_paths()
    RETURNS TRIGGER AS $$
    BEGIN
      IF NEW.full_path != OLD.full_path THEN
        WITH RECURSIVE descendants AS (
          SELECT id, full_path
          FROM paths
          WHERE parent_id = NEW.id

          UNION ALL

          SELECT p.id, p.full_path
          FROM paths p
          INNER JOIN descendants d ON p.parent_id = d.id
        )
        UPDATE paths
        SET full_path = REPLACE(paths.full_path, OLD.full_path, NEW.full_path),
            updated_at = NOW()
        FROM descendants
        WHERE paths.id = descendants.id;
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """

    execute """
    CREATE TRIGGER trigger_update_descendant_full_paths
    AFTER UPDATE OF path, parent_id
    ON paths
    FOR EACH ROW
    WHEN (OLD.full_path IS DISTINCT FROM NEW.full_path)
    EXECUTE FUNCTION update_descendant_full_paths();
    """
  end

  def down do
    execute "DROP INDEX IF EXISTS paths_unique_sibling_path"

    execute "DROP TRIGGER IF EXISTS trigger_update_descendant_full_paths ON paths"
    execute "DROP FUNCTION IF EXISTS update_descendant_full_paths()"

    execute "DROP TRIGGER IF EXISTS trigger_prevent_mount_when_has_children ON paths"
    execute "DROP FUNCTION IF EXISTS prevent_mount_when_has_children()"

    execute "DROP TRIGGER IF EXISTS trigger_prevent_child_under_mount ON paths"
    execute "DROP FUNCTION IF EXISTS prevent_child_under_mount()"

    execute "DROP TRIGGER IF EXISTS trigger_compute_full_path ON paths"
    execute "DROP FUNCTION IF EXISTS compute_full_path()"

    drop table(:paths)
  end
end
