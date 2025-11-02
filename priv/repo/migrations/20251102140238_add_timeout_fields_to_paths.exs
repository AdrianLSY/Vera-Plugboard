defmodule Plugboard.Repo.Migrations.AddTimeoutFieldsToPaths do
  use Ecto.Migration

  def change do
    alter table(:paths) do
      add :request_timeout_ms, :integer, default: 60000, null: false
      add :connect_timeout_ms, :integer, default: 5000, null: false
    end
  end
end
