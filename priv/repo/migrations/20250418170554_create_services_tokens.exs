defmodule Vera.Repo.Migrations.CreateServicesTokens do
  use Ecto.Migration

  def change do
    create table(:services_tokens) do
      add :token, :binary, null: false
      add :context, :string, null: false
      add :service_id, references(:services, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:services_tokens, [:service_id])
    create unique_index(:services_tokens, [:context, :token])
  end
end
