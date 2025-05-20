defmodule Plugboard.Repo.Migrations.AddServiceRegexToAccount do
  use Ecto.Migration

  def change do
    alter table(:accounts) do
      add :service_regex, :string, default: "^$", null: false
    end
  end
end
