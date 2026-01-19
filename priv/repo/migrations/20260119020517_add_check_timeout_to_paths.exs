defmodule Plugboard.Repo.Migrations.AddCheckTimeoutToPaths do
  use Ecto.Migration

  def change do
    alter table(:paths) do
      add(:check_timeout_ms, :integer,
        null: true,
        comment: "WebSocket check timeout in milliseconds (overrides default)"
      )
    end
  end
end
