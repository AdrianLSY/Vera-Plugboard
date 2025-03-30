defmodule Vera.Repo.Migrations.CreateServices do
  use Ecto.Migration

  def change do
    create table(:services) do
      add :name, :string
      add :parent_id, references(:services, on_delete: :delete_all), null: true
      add :num_children, :integer, default: 0
      add :num_descendants, :integer, default: 0
      timestamps(type: :utc_datetime)
    end
  end
end
