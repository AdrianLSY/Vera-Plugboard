defmodule Plugboard.Repo.Migrations.FixPreventChildUnderMountTrigger do
  use Ecto.Migration

  def up do
    # Drop existing trigger and function
    execute "DROP TRIGGER IF EXISTS trigger_prevent_child_under_mount ON paths"
    execute "DROP FUNCTION IF EXISTS prevent_child_under_mount()"

    # Recreate with FOR UPDATE lock to prevent race conditions
    execute """
    CREATE OR REPLACE FUNCTION prevent_child_under_mount()
    RETURNS TRIGGER AS $$
    DECLARE
      parent_is_mount BOOLEAN;
    BEGIN
      IF NEW.parent_id IS NOT NULL THEN
        -- Lock parent row to prevent concurrent mount_point updates
        SELECT mount_point INTO parent_is_mount
        FROM paths
        WHERE id = NEW.parent_id
        AND deleted_at IS NULL
        FOR UPDATE;

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
  end

  def down do
    # Revert to original version without FOR UPDATE
    execute "DROP TRIGGER IF EXISTS trigger_prevent_child_under_mount ON paths"
    execute "DROP FUNCTION IF EXISTS prevent_child_under_mount()"

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
  end
end
