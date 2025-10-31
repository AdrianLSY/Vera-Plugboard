defmodule Plugboard.Paths do
  @moduledoc """
  The Paths context for managing path hierarchy and mount points.

  This context handles:
  - Creating, updating, and soft-deleting paths
  - Restoring soft-deleted paths
  - Querying paths and mount points
  - Enforcing ownership and permissions
  """

  import Ecto.Query, warn: false
  alias Plugboard.Repo
  alias Plugboard.Paths.Path

  @doc """
  Returns the list of active paths for a given user.

  ## Examples

      iex> list_paths(user_id)
      [%Path{}, ...]

  """
  def list_paths(user_id) do
    Path
    |> where([p], p.user_id == ^user_id)
    |> where([p], is_nil(p.deleted_at))
    |> order_by([p], asc: p.full_path)
    |> Repo.all()
  end

  @doc """
  Returns the list of active mount points for a given user.

  ## Examples

      iex> list_mount_points(user_id)
      [%Path{}, ...]

  """
  def list_mount_points(user_id) do
    Path
    |> where([p], p.user_id == ^user_id)
    |> where([p], p.mount_point == true)
    |> where([p], is_nil(p.deleted_at))
    |> order_by([p], asc: p.full_path)
    |> Repo.all()
  end

  @doc """
  Gets a single path by ID.

  Returns `nil` if the Path does not exist or is soft-deleted.

  ## Examples

      iex> get_path(123)
      %Path{}

      iex> get_path(456)
      nil

  """
  def get_path(id) do
    Path
    |> where([p], is_nil(p.deleted_at))
    |> Repo.get(id)
  end

  @doc """
  Gets a single path by ID, including soft-deleted paths.

  ## Examples

      iex> get_path!(123)
      %Path{}

  """
  def get_path!(id) do
    Repo.get!(Path, id)
  end

  @doc """
  Gets a path by full_path for a specific user.

  Returns `nil` if the Path does not exist or is soft-deleted.

  ## Examples

      iex> get_path_by_full_path(user_id, "/xyz/todo")
      %Path{}

  """
  def get_path_by_full_path(user_id, full_path) do
    Path
    |> where([p], p.user_id == ^user_id)
    |> where([p], p.full_path == ^full_path)
    |> where([p], is_nil(p.deleted_at))
    |> Repo.one()
  end

  @doc """
  Gets a path by full_path for a specific user, including soft-deleted paths.

  ## Examples

      iex> get_path_by_full_path_including_deleted(user_id, "/xyz/todo")
      %Path{}

  """
  def get_path_by_full_path_including_deleted(user_id, full_path) do
    Path
    |> where([p], p.user_id == ^user_id)
    |> where([p], p.full_path == ^full_path)
    |> Repo.one()
  end

  @doc """
  Creates a path.

  If a path with the same full_path exists and is soft-deleted, it will be restored
  instead of creating a new record. The restored path will have mount_point set to false.

  ## Examples

      iex> create_path(%{path: "xyz", user_id: user_id, created_by_user_id: user_id})
      {:ok, %Path{}}

      iex> create_path(%{path: "", user_id: user_id})
      {:error, %Ecto.Changeset{}}

  """
  def create_path(attrs \\ %{}) do
    # First, validate the changeset
    changeset = Path.create_changeset(%Path{}, attrs)

    if changeset.valid? do
      # Check if there's a soft-deleted path to restore
      case check_for_soft_deleted(changeset) do
        {:ok, nil} ->
          # No soft-deleted path found, create new
          case Repo.insert(changeset) do
            {:ok, path} ->
              # Reload to get trigger-computed full_path
              {:ok, Repo.get!(Path, path.id)}

            error ->
              error
          end

        {:ok, path} ->
          # Restore the soft-deleted path
          case Path.restore_changeset(path, attrs) |> Repo.update() do
            {:ok, path} ->
              # Reload to get trigger-computed full_path
              {:ok, Repo.get!(Path, path.id)}

            error ->
              error
          end
      end
    else
      {:error, changeset}
    end
  end

  defp check_for_soft_deleted(changeset) do
    user_id = Ecto.Changeset.get_field(changeset, :user_id)
    path_segment = Ecto.Changeset.get_field(changeset, :path)
    parent_id = Ecto.Changeset.get_field(changeset, :parent_id)

    # Check for soft-deleted path with same user_id, parent_id, and path
    query =
      Path
      |> where([p], p.user_id == ^user_id)
      |> where([p], p.path == ^path_segment)
      |> where([p], not is_nil(p.deleted_at))

    # Handle parent_id - could be nil for root paths
    query =
      if is_nil(parent_id) do
        where(query, [p], is_nil(p.parent_id))
      else
        where(query, [p], p.parent_id == ^parent_id)
      end

    case Repo.one(query) do
      nil ->
        {:ok, nil}

      path ->
        {:ok, path}
    end
  end

  @doc """
  Updates a path.

  Note: Updating the path segment will trigger full_path recomputation for the path
  and all its descendants.

  ## Examples

      iex> update_path(path, %{mount_point: true})
      {:ok, %Path{}}

      iex> update_path(path, %{path: ""})
      {:error, %Ecto.Changeset{}}

  """
  def update_path(%Path{} = path, attrs) do
    case path
         |> Path.update_changeset(attrs)
         |> Repo.update() do
      {:ok, updated} ->
        # Reload to get trigger-computed full_path
        {:ok, Repo.get!(Path, updated.id)}

      error ->
        error
    end
  end

  @doc """
  Soft-deletes a path by setting deleted_at timestamp.

  Children are also soft-deleted recursively.

  ## Examples

      iex> delete_path(path)
      {:ok, %Path{}}

  """
  def delete_path(%Path{} = path) do
    deleted_at = DateTime.utc_now() |> DateTime.truncate(:second)

    # Soft-delete all descendants first
    query = """
    WITH RECURSIVE descendants AS (
      SELECT id
      FROM paths
      WHERE parent_id = $1
        AND deleted_at IS NULL

      UNION ALL

      SELECT p.id
      FROM paths p
      INNER JOIN descendants d ON p.parent_id = d.id
      WHERE p.deleted_at IS NULL
    )
    UPDATE paths
    SET deleted_at = $2, updated_at = $2
    WHERE id IN (SELECT id FROM descendants)
    """

    {:ok, uuid_binary} = Ecto.UUID.dump(path.id)
    Repo.query!(query, [uuid_binary, deleted_at])

    # Then soft-delete the path itself
    path
    |> Path.delete_changeset()
    |> Repo.update()
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking path changes.

  ## Examples

      iex> change_path(path)
      %Ecto.Changeset{data: %Path{}}

  """
  def change_path(%Path{} = path, attrs \\ %{}) do
    Path.update_changeset(path, attrs)
  end

  @doc """
  Checks if a path can be marked as a mount point.

  Returns {:ok, true} if it can be marked as mount, or {:error, reason} if not.

  ## Examples

      iex> can_mark_as_mount?(path)
      {:ok, true}

      iex> can_mark_as_mount?(path_with_children)
      {:error, "Cannot mark path as mount point when it has children"}

  """
  def can_mark_as_mount?(%Path{} = path) do
    child_count =
      Path
      |> where([p], p.parent_id == ^path.id)
      |> where([p], is_nil(p.deleted_at))
      |> Repo.aggregate(:count)

    if child_count > 0 do
      {:error, "Cannot mark path as mount point when it has children"}
    else
      {:ok, true}
    end
  end

  @doc """
  Checks if a path can have children (i.e., it's not a mount point).

  Returns {:ok, true} if children can be added, or {:error, reason} if not.

  ## Examples

      iex> can_add_child?(path)
      {:ok, true}

      iex> can_add_child?(mount_point)
      {:error, "Cannot create child path under a mount point"}

  """
  def can_add_child?(%Path{mount_point: true}) do
    {:error, "Cannot create child path under a mount point"}
  end

  def can_add_child?(%Path{}) do
    {:ok, true}
  end

  @doc """
  Gets all children of a path (non-recursive, direct children only).

  ## Examples

      iex> get_children(path)
      [%Path{}, ...]

  """
  def get_children(%Path{} = path) do
    Path
    |> where([p], p.parent_id == ^path.id)
    |> where([p], is_nil(p.deleted_at))
    |> order_by([p], asc: p.path)
    |> Repo.all()
  end

  @doc """
  Gets all descendants of a path recursively.

  ## Examples

      iex> get_descendants(path)
      [%Path{}, ...]

  """
  def get_descendants(%Path{} = path) do
    query = """
    WITH RECURSIVE descendants AS (
      SELECT id, user_id, created_by_user_id, parent_id, path, full_path,
             mount_point, inserted_at, updated_at, deleted_at
      FROM paths
      WHERE parent_id = $1
        AND deleted_at IS NULL

      UNION ALL

      SELECT p.id, p.user_id, p.created_by_user_id, p.parent_id, p.path, p.full_path,
             p.mount_point, p.inserted_at, p.updated_at, p.deleted_at
      FROM paths p
      INNER JOIN descendants d ON p.parent_id = d.id
      WHERE p.deleted_at IS NULL
    )
    SELECT * FROM descendants
    ORDER BY full_path
    """

    # Convert binary_id to binary for Postgrex
    {:ok, uuid_binary} = Ecto.UUID.dump(path.id)
    result = Repo.query!(query, [uuid_binary])

    Enum.map(result.rows, fn row ->
      Repo.load(Path, {result.columns, row})
    end)
  end
end
