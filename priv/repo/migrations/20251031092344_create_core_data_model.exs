defmodule Plugboard.Repo.Migrations.CreateCoreDataModel do
  use Ecto.Migration

  def change do
    create table(:paths, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :account_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :created_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all),
        null: false

      add :parent_id, references(:paths, type: :binary_id, on_delete: :delete_all), null: true
      add :path, :text, null: false
      add :full_path, :text, null: false
      add :mount_point, :boolean, default: false, null: false
      timestamps()
      add :deleted_at, :timestamptz, null: true
    end

    create unique_index(:paths, [:account_id, :parent_id, :path],
             name: :paths_unique_sibling_path
           )

    create index(:paths, [:full_path], name: :idx_paths_full_path)
    create index(:paths, [:mount_point, :full_path], name: :idx_paths_mount_point_full_path)
  end
end
