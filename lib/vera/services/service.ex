defmodule Vera.Services.Service do
  use Ecto.Schema
  import Ecto.Changeset

  schema "services" do
    field :name, :string
    belongs_to :parent, Vera.Services.Service
    has_many :children, Vera.Services.Service, foreign_key: :parent_id
    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(service, attrs) do
    service
    |> cast(attrs, [:name])
    |> validate_required([:name])
  end
end
