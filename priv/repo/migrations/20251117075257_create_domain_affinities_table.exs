defmodule Plugboard.Repo.Migrations.CreateDomainAffinitiesTable do
  use Ecto.Migration

  def up do
    create table(:domain_affinities, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :domain, :text, null: false
      add :path_id, references(:paths, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
      add :deleted_at, :utc_datetime
    end

    # Unique constraint on domain (only active records)
    create unique_index(:domain_affinities, [:domain],
             where: "deleted_at IS NULL",
             name: :domain_affinities_unique_domain
           )

    # Index for path lookups
    create index(:domain_affinities, [:path_id])

    # Domain format validation (supports exact and wildcard domains)
    execute """
    ALTER TABLE domain_affinities
    ADD CONSTRAINT valid_domain_format
    CHECK (domain ~ '^(\\*\\.)?[a-z0-9][a-z0-9\\-\\.]*[a-z0-9]$')
    """

    # Create trigger function for PostgreSQL NOTIFY
    execute """
    CREATE OR REPLACE FUNCTION notify_domain_affinity_change()
    RETURNS TRIGGER AS $$
    DECLARE
      payload JSON;
      path_full_path TEXT;
    BEGIN
      IF (TG_OP = 'DELETE' OR (TG_OP = 'UPDATE' AND NEW.deleted_at IS NOT NULL)) THEN
        -- Domain affinity removed
        payload = json_build_object(
          'action', 'domain_affinity_removed',
          'domain', OLD.domain
        );
        PERFORM pg_notify('plugboard_domain_affinities', payload::text);
        RETURN OLD;
      ELSIF (TG_OP = 'INSERT' OR (TG_OP = 'UPDATE' AND OLD.deleted_at IS NOT NULL AND NEW.deleted_at IS NULL)) THEN
        -- Domain affinity added - need to get the path's full_path
        SELECT full_path INTO path_full_path
        FROM paths
        WHERE id = NEW.path_id;

        payload = json_build_object(
          'action', 'domain_affinity_added',
          'domain', NEW.domain,
          'path_id', NEW.path_id,
          'full_path', path_full_path
        );
        PERFORM pg_notify('plugboard_domain_affinities', payload::text);
        RETURN NEW;
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """

    # Create trigger
    execute """
    CREATE TRIGGER domain_affinity_change_trigger
    AFTER INSERT OR UPDATE OR DELETE ON domain_affinities
    FOR EACH ROW EXECUTE FUNCTION notify_domain_affinity_change();
    """
  end

  def down do
    execute "DROP TRIGGER IF EXISTS domain_affinity_change_trigger ON domain_affinities"
    execute "DROP FUNCTION IF EXISTS notify_domain_affinity_change()"
    drop table(:domain_affinities)
  end
end
