defmodule Vera.Repo.Migrations.CreateServices do
  use Ecto.Migration

  def change do
    create table(:services) do
      add :name, :string
      add :parent_id, references(:services, on_delete: :delete_all), null: true
      add :deleted_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create index(:services, [:inserted_at])
    create index(:services, [:updated_at])
    create index(:services, [:deleted_at])
    create index(:services, [:parent_id])
  end
end
