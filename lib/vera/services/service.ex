defmodule Vera.Services.Service do
  use Ecto.Schema
  import Ecto.Query
  import Ecto.Changeset

  @derive {Jason.Encoder, only: [:id, :name, :inserted_at, :updated_at]}

  schema "services" do
    field :name, :string
    belongs_to :parent, Vera.Services.Service
    has_many :children, Vera.Services.Service, foreign_key: :parent_id, where: [deleted_at: nil]
    field :deleted_at, :utc_datetime
    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(service, attrs) do
    service
    |> cast(attrs, [:name, :parent_id])
    |> validate_required([:name])
  end

  def default_scope do
    from(s in __MODULE__, where: is_nil(s.deleted_at))
  end

  @doc """
  Returns the list of descendants of a service ordered by their hierarchy level.
  Descendants include all children, grandchildren, and further nested services.

  The results are ordered by their level in the hierarchy, with direct children first,
  followed by grandchildren, and so on.

  ## Examples

      iex> service = %Service{id: 1, name: "Parent"}
      iex> descendants(service)
      [
        %Service{id: 2, name: "Child", parent_id: 1},
        %Service{id: 3, name: "Grandchild", parent_id: 2},
        ...
      ]
  """
  def descendants(service) do
    Vera.Repo.all(
      from s in __MODULE__,
      where: fragment(
        "? IN (
          WITH RECURSIVE descendants AS (
            SELECT id, parent_id, name, 1 as level
            FROM services
            WHERE parent_id = ? AND deleted_at IS NULL
            UNION ALL
            SELECT s.id, s.parent_id, s.name, d.level + 1
            FROM services s
            INNER JOIN descendants d ON s.parent_id = d.id
            WHERE s.deleted_at IS NULL
          )
          SELECT id FROM descendants
        )",
        s.id,
        ^service.id
      ),
      order_by: fragment("(
        WITH RECURSIVE descendants AS (
          SELECT id, parent_id, name, 1 as level
          FROM services
          WHERE parent_id = ? AND deleted_at IS NULL
          UNION ALL
          SELECT s.id, s.parent_id, s.name, d.level + 1
          FROM services s
          INNER JOIN descendants d ON s.parent_id = d.id
          WHERE s.deleted_at IS NULL
        )
        SELECT level FROM descendants WHERE id = ?
      )", ^service.id, field(s, :id))
    )
  end

  @doc """
  Returns the path from root service to the current service as an ordered list.
  The result includes all services in the path from the root (topmost ancestor)
  to the current service, inclusive.

  The results are ordered from root to current service, making it useful for
  building breadcrumb trails or displaying complete hierarchical paths.

  ## Examples

      iex> service = %Service{id: 3, name: "Grandchild", parent_id: 2}
      iex> full_path(service)
      [
        %Service{id: 1, name: "Root", parent_id: nil},
        %Service{id: 2, name: "Parent", parent_id: 1},
        %Service{id: 3, name: "Grandchild", parent_id: 2}
      ]

  """
  def full_path(service) do
    Vera.Repo.all(
      from s in __MODULE__,
      where: fragment(
        "? IN (
          WITH RECURSIVE ancestors AS (
            SELECT id, parent_id, name, 1 as level
            FROM services
            WHERE id = ?
            UNION ALL
            SELECT s.id, s.parent_id, s.name, a.level - 1
            FROM services s
            INNER JOIN ancestors a ON s.id = a.parent_id
          )
          SELECT id FROM ancestors
          ORDER BY level
        )",
        s.id,
        ^service.id
      ),
      order_by: fragment("(
        WITH RECURSIVE ancestors AS (
          SELECT id, parent_id, name, 1 as level
          FROM services
          WHERE id = ?
          UNION ALL
          SELECT s.id, s.parent_id, s.name, a.level - 1
          FROM services s
          INNER JOIN ancestors a ON s.id = a.parent_id
        )
        SELECT level FROM ancestors WHERE id = ?
      )", ^service.id, field(s, :id))
    )
  end
end
