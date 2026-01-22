defmodule Plugboard.Repo.Migrations.AddMountNotifyTrigger do
  use Ecto.Migration

  def up do
    # Create function to send NOTIFY on mount point changes
    execute """
    CREATE OR REPLACE FUNCTION notify_mount_change()
    RETURNS TRIGGER AS $$
    DECLARE
      payload JSON;
    BEGIN
      -- Handle INSERT
      IF (TG_OP = 'INSERT' AND NEW.mount_point = TRUE AND NEW.deleted_at IS NULL) THEN
        payload := json_build_object(
          'action', 'mount_added',
          'full_path', NEW.full_path
        );
        PERFORM pg_notify('plugboard_mounts', payload::text);
        RETURN NEW;
      END IF;

      -- Handle UPDATE
      IF (TG_OP = 'UPDATE') THEN
        -- Mount point was added (became true)
        IF (OLD.mount_point = FALSE AND NEW.mount_point = TRUE AND NEW.deleted_at IS NULL) THEN
          payload := json_build_object(
            'action', 'mount_added',
            'full_path', NEW.full_path
          );
          PERFORM pg_notify('plugboard_mounts', payload::text);

        -- Mount point was removed (became false)
        ELSIF (OLD.mount_point = TRUE AND NEW.mount_point = FALSE) THEN
          payload := json_build_object(
            'action', 'mount_removed',
            'full_path', OLD.full_path
          );
          PERFORM pg_notify('plugboard_mounts', payload::text);

        -- Mount point path changed (full_path changed while still a mount)
        ELSIF (NEW.mount_point = TRUE AND OLD.full_path != NEW.full_path AND NEW.deleted_at IS NULL) THEN
          -- Remove old path
          payload := json_build_object(
            'action', 'mount_removed',
            'full_path', OLD.full_path
          );
          PERFORM pg_notify('plugboard_mounts', payload::text);

          -- Add new path
          payload := json_build_object(
            'action', 'mount_added',
            'full_path', NEW.full_path
          );
          PERFORM pg_notify('plugboard_mounts', payload::text);

        -- Mount was soft-deleted
        ELSIF (NEW.mount_point = TRUE AND OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL) THEN
          payload := json_build_object(
            'action', 'mount_removed',
            'full_path', OLD.full_path
          );
          PERFORM pg_notify('plugboard_mounts', payload::text);

        -- Mount was restored from soft-delete
        ELSIF (NEW.mount_point = TRUE AND OLD.deleted_at IS NOT NULL AND NEW.deleted_at IS NULL) THEN
          payload := json_build_object(
            'action', 'mount_added',
            'full_path', NEW.full_path
          );
          PERFORM pg_notify('plugboard_mounts', payload::text);
        END IF;

        RETURN NEW;
      END IF;

      -- Handle DELETE (shouldn't happen with soft-delete, but handle anyway)
      IF (TG_OP = 'DELETE' AND OLD.mount_point = TRUE) THEN
        payload := json_build_object(
          'action', 'mount_removed',
          'full_path', OLD.full_path
        );
        PERFORM pg_notify('plugboard_mounts', payload::text);
        RETURN OLD;
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """

    # Create trigger on paths table
    execute """
    CREATE TRIGGER paths_mount_notify_trigger
    AFTER INSERT OR UPDATE OR DELETE ON paths
    FOR EACH ROW
    EXECUTE FUNCTION notify_mount_change();
    """
  end

  def down do
    execute "DROP TRIGGER IF EXISTS paths_mount_notify_trigger ON paths;"
    execute "DROP FUNCTION IF EXISTS notify_mount_change();"
  end
end
