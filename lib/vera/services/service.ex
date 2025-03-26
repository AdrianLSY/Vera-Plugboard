defmodule Vera.Services.Service do
  use Ecto.Schema
  import Ecto.Changeset

  schema "services" do
    field :name, :string

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(service, attrs) do
    service
    |> cast(attrs, [:name])
    |> validate_required([:name])
  end
end
