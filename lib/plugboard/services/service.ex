defmodule Plugboard.Services.Service do
  use Ecto.Schema
  import Ecto.Query
  import Ecto.Changeset
  alias Plugboard.Services.ServiceManager

  @derive {Jason.Encoder, only: [:id, :name, :inserted_at, :updated_at]}

  schema "services" do
    field :name, :string
    belongs_to :parent, Plugboard.Services.Service
    has_many :children, Plugboard.Services.Service, foreign_key: :parent_id, where: [deleted_at: nil]
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
  Creates a service and starts its associated GenServer.
  """
  def create(attrs) do
    result =
      %__MODULE__{}
      |> changeset(attrs)
      |> Plugboard.Repo.insert()

    case result do
      {:ok, service} ->
        # Start the service's GenServer
        ServiceManager.handle_service_created(service)
        result
      error -> error
    end
  end

  # @doc """
  # Soft deletes a service and stops its associated GenServer.
  # """
  def delete(service) do
    result =
      service
      |> change(%{deleted_at: DateTime.utc_now()})
      |> Plugboard.Repo.update()

    case result do
      {:ok, _service} ->
        # TODO: Handle undeleting a service
        # Genservers are not automatically restarted when a service is undeleted.
        # For now, we will just keep genservers running for soft deleted services.
        # ServiceManager.handle_service_deleted(service)
        result
      error -> error
    end
  end

  @doc """
  Returns the list of descendants of a service ordered by their hierarchy level.
  Descendants include all children, grandchildren, and further nested services.

  The results are ordered by their level in the hierarchy, with direct children first,
  followed by grandchildren, and so on.
  """
  def descendants(service) do
    Plugboard.Repo.all(
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
  """
  def full_path(service) do
    Plugboard.Repo.all(
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
