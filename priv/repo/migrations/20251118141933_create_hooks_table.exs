defmodule Plugboard.Repo.Migrations.CreateHooksTable do
  use Ecto.Migration

  def up do
    create table(:hooks, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # Association
      add :path_id, references(:paths, type: :binary_id, on_delete: :delete_all), null: false

      # Hook Configuration
      add :name, :string, null: false
      add :description, :text

      # Target Configuration (supports both internal mount points and external HTTP)
      add :target_type, :string, null: false, default: "mount_point"
      add :target_path_id, references(:paths, type: :binary_id, on_delete: :restrict)
      add :target_url, :text

      # Execution Configuration
      add :execution_order, :integer, null: false, default: 0
      add :timeout_ms, :integer, null: false, default: 5000

      # Status Code Whitelisting
      add :allowed_status_codes, :jsonb, null: false, default: "[200, 201, 202, 204]"

      # Request Configuration
      add :forward_headers, :jsonb, default: "[]"
      add :forward_query_params, :boolean, default: false

      # Soft Delete
      add :deleted_at, :utc_datetime

      # Timestamps
      timestamps(type: :utc_datetime)
    end

    # Indexes
    create index(:hooks, [:path_id], where: "deleted_at IS NULL")

    create index(:hooks, [:path_id, :execution_order],
             where: "deleted_at IS NULL",
             name: :hooks_path_order_index
           )

    # Unique constraint on execution order per path (prevents duplicates)
    create unique_index(:hooks, [:path_id, :execution_order],
             where: "deleted_at IS NULL",
             name: :hooks_unique_execution_order
           )

    # Constraint: target_type must be 'mount_point' or 'http_url'
    execute """
    ALTER TABLE hooks
    ADD CONSTRAINT valid_target_type
    CHECK (target_type IN ('mount_point', 'http_url'))
    """

    # Constraint: target_path_id required if target_type = 'mount_point'
    # Constraint: target_url required if target_type = 'http_url'
    execute """
    ALTER TABLE hooks
    ADD CONSTRAINT valid_target_config
    CHECK (
      (target_type = 'mount_point' AND target_path_id IS NOT NULL AND target_url IS NULL) OR
      (target_type = 'http_url' AND target_url IS NOT NULL AND target_path_id IS NULL)
    )
    """

    # Constraint: timeout must be between 1ms and 60s
    execute """
    ALTER TABLE hooks
    ADD CONSTRAINT valid_timeout
    CHECK (timeout_ms > 0 AND timeout_ms <= 60000)
    """

    # Constraint: execution_order must be >= 0
    execute """
    ALTER TABLE hooks
    ADD CONSTRAINT valid_execution_order
    CHECK (execution_order >= 0)
    """

    # Trigger function for PostgreSQL NOTIFY on hook changes
    execute """
    CREATE OR REPLACE FUNCTION notify_hook_change()
    RETURNS TRIGGER AS $$
    DECLARE
      payload JSON;
    BEGIN
      IF TG_OP = 'INSERT' OR TG_OP = 'UPDATE' THEN
        -- Only notify if the hook is active (not deleted)
        IF NEW.deleted_at IS NULL THEN
          payload := json_build_object(
            'action', 'hook_updated',
            'path_id', NEW.path_id,
            'hook_id', NEW.id
          );
          PERFORM pg_notify('plugboard_hooks', payload::text);
        ELSIF OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL THEN
          -- Hook was soft-deleted
          payload := json_build_object(
            'action', 'hook_deleted',
            'path_id', NEW.path_id,
            'hook_id', NEW.id
          );
          PERFORM pg_notify('plugboard_hooks', payload::text);
        END IF;
      ELSIF TG_OP = 'DELETE' THEN
        -- Hard delete (shouldn't happen but handle anyway)
        payload := json_build_object(
          'action', 'hook_deleted',
          'path_id', OLD.path_id,
          'hook_id', OLD.id
        );
        PERFORM pg_notify('plugboard_hooks', payload::text);
      END IF;
      RETURN NULL;
    END;
    $$ LANGUAGE plpgsql;
    """

    # Create trigger
    execute """
    CREATE TRIGGER trigger_notify_hook_change
    AFTER INSERT OR UPDATE OR DELETE ON hooks
    FOR EACH ROW EXECUTE FUNCTION notify_hook_change();
    """
  end

  def down do
    execute "DROP TRIGGER IF EXISTS trigger_notify_hook_change ON hooks"
    execute "DROP FUNCTION IF EXISTS notify_hook_change()"
    drop table(:hooks)
  end
end
