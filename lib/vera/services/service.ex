defmodule Vera.Services.Service do
  use Ecto.Schema
  import Ecto.Query
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

  @doc """
  Returns the list of descendants of a service.
  More specifically it returns the service children and their children, etc.

  ## Examples

      iex> descendants(service)
      [%Service{}, ...]
  """
  def descendants(service) do
    Vera.Repo.all(
      from s in __MODULE__,
      where: fragment(
        "? IN (
          WITH RECURSIVE descendants AS (
            SELECT id, parent_id
            FROM services
            WHERE parent_id = ?
            UNION ALL
            SELECT s.id, s.parent_id
            FROM services s
            INNER JOIN descendants d ON d.id = s.parent_id
          )
          SELECT id FROM descendants
        )",
        s.id,
        ^service.id
      )
    )
  end
end
