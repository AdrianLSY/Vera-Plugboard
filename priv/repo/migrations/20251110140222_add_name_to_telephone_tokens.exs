defmodule Plugboard.Repo.Migrations.AddNameToTelephoneTokens do
  use Ecto.Migration

  def change do
    alter table(:telephone_tokens) do
      add :name, :string
    end
  end
end
