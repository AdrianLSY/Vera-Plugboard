defmodule Plugboard.Repo.Migrations.AddQueryOptimizationIndexes do
  use Ecto.Migration

  def up do
    # 1. Partial index on paths.deleted_at for active records
    # Benefits: Almost every query filters WHERE deleted_at IS NULL
    # This dramatically reduces index size and speeds up lookups
    create index(:paths, [:deleted_at],
             where: "deleted_at IS NULL",
             name: :idx_paths_active_only
           )

    # 2. Composite index for parent-child queries with deleted_at filter
    # Benefits: list_paths_by_parent queries filter by parent_id and deleted_at
    # Includes 'path' for covering index to avoid table lookup during ORDER BY
    create index(:paths, [:parent_id, :deleted_at, :path],
             where: "deleted_at IS NULL",
             name: :idx_paths_parent_active_path
           )

    # 3. Composite index for mount point queries
    # Benefits: list_mount_points filters by mount_point=true and deleted_at IS NULL
    # Includes full_path for covering index to support ORDER BY without table lookup
    create index(:paths, [:mount_point, :deleted_at, :full_path],
             where: "deleted_at IS NULL AND mount_point = true",
             name: :idx_paths_mount_points_active
           )

    # 4. Composite covering index on user_paths for efficient JOINs
    # Benefits: Most queries JOIN user_paths WHERE user_id = ? AND path_id = ?
    # The unique index already exists, but we create a covering index with role
    # to avoid table lookups when selecting user_path details
    create index(:user_paths, [:user_id, :path_id, :role], name: :idx_user_paths_covering)

    # 5. Composite index for path_id lookups with role filtering
    # Benefits: Speeds up list_path_users and role-based queries
    create index(:user_paths, [:path_id, :role], name: :idx_user_paths_path_role)

    # 6. Index on paths.id with deleted_at for efficient get_path queries
    # Benefits: get_path and similar queries filter by id AND deleted_at IS NULL
    create index(:paths, [:id, :deleted_at],
             where: "deleted_at IS NULL",
             name: :idx_paths_id_active
           )

    # 7. Composite index for full_path lookups on active paths
    # Benefits: get_path_by_full_path queries filter by full_path and deleted_at
    # This is a covering index that includes id for JOIN optimization
    create index(:paths, [:full_path, :deleted_at, :id],
             where: "deleted_at IS NULL",
             name: :idx_paths_full_path_active_covering
           )

    # Remove the now-redundant standalone full_path index since we have a better covering index
    drop_if_exists index(:paths, [:full_path], name: :idx_paths_full_path)

    # 8. Index for recursive descendant queries
    # Benefits: CTE queries in get_descendants and delete_path use parent_id heavily
    # The existing idx_paths_parent_id is good, but we can optimize further with deleted_at
    # Note: We already have idx_paths_parent_active_path which covers this
  end

  def down do
    # Restore the original full_path index
    create index(:paths, [:full_path], name: :idx_paths_full_path)

    drop_if_exists index(:paths, [:full_path, :deleted_at, :id],
                     name: :idx_paths_full_path_active_covering
                   )

    drop_if_exists index(:paths, [:id, :deleted_at], name: :idx_paths_id_active)

    drop_if_exists index(:user_paths, [:path_id, :role], name: :idx_user_paths_path_role)

    drop_if_exists index(:user_paths, [:user_id, :path_id, :role], name: :idx_user_paths_covering)

    drop_if_exists index(:paths, [:mount_point, :deleted_at, :full_path],
                     name: :idx_paths_mount_points_active
                   )

    drop_if_exists index(:paths, [:parent_id, :deleted_at, :path],
                     name: :idx_paths_parent_active_path
                   )

    drop_if_exists index(:paths, [:deleted_at], name: :idx_paths_active_only)
  end
end
