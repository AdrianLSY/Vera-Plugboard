defmodule Vera.Services.Service do
  use Ecto.Schema
  import Ecto.Changeset

  schema "services" do
    field :name, :string
    field :num_children, :integer, default: 0
    field :num_descendants, :integer, default: 0
    belongs_to :parent, Vera.Services.Service
    has_many :children, Vera.Services.Service, foreign_key: :parent_id
    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(service, attrs) do
    service
    |> cast(attrs, [:name, :parent_id])
    |> validate_required([:name])
  end
end
