defmodule Plugboard.Paths do
  @moduledoc """
  The Paths context for managing path hierarchy and mount points.

  This context handles:
  - Creating, updating, and soft-deleting paths
  - Restoring soft-deleted paths
  - Querying paths and mount points
  - Managing user-path associations with roles (owner, maintainer, viewer)
  - Enforcing ownership and permissions
  """

  import Ecto.Query, warn: false
  alias Plugboard.Repo
  alias Plugboard.Paths.Path
  alias Plugboard.Paths.UserPath

  @doc """
  Returns the list of active paths for a given user.

  ## Examples

      iex> list_paths(user_id)
      [%Path{}, ...]

  """
  def list_paths(user_id) do
    from(p in Path,
      join: up in UserPath,
      on: up.path_id == p.id,
      where: up.user_id == ^user_id,
      where: is_nil(p.deleted_at),
      order_by: [asc: p.full_path]
    )
    |> Repo.all()
  end

  @doc """
  Returns the list of active paths for a given user filtered by parent_id.

  When parent_id is nil, returns root-level paths.
  When parent_id is set, returns direct children of that path.

  ## Examples

      iex> list_paths_by_parent(user_id, nil)
      [%Path{parent_id: nil}, ...]

      iex> list_paths_by_parent(user_id, parent_id)
      [%Path{parent_id: ^parent_id}, ...]

  """
  def list_paths_by_parent(user_id, nil) do
    from(p in Path,
      join: up in UserPath,
      on: up.path_id == p.id,
      where: up.user_id == ^user_id,
      where: is_nil(p.parent_id),
      where: is_nil(p.deleted_at),
      order_by: [asc: p.path]
    )
    |> Repo.all()
  end

  def list_paths_by_parent(user_id, parent_id) do
    from(p in Path,
      join: up in UserPath,
      on: up.path_id == p.id,
      where: up.user_id == ^user_id,
      where: p.parent_id == ^parent_id,
      where: is_nil(p.deleted_at),
      order_by: [asc: p.path]
    )
    |> Repo.all()
  end

  @doc """
  Returns the list of active mount points for a given user.

  ## Examples

      iex> list_mount_points(user_id)
      [%Path{}, ...]

  """
  def list_mount_points(user_id) do
    from(p in Path,
      join: up in UserPath,
      on: up.path_id == p.id,
      where: up.user_id == ^user_id,
      where: p.mount_point == true,
      where: is_nil(p.deleted_at),
      order_by: [asc: p.full_path]
    )
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
    from(p in Path,
      join: up in UserPath,
      on: up.path_id == p.id,
      where: up.user_id == ^user_id,
      where: p.full_path == ^full_path,
      where: is_nil(p.deleted_at)
    )
    |> Repo.one()
  end

  @doc """
  Gets a path by full_path for a specific user, including soft-deleted paths.

  ## Examples

      iex> get_path_by_full_path_including_deleted(user_id, "/xyz/todo")
      %Path{}

  """
  def get_path_by_full_path_including_deleted(user_id, full_path) do
    from(p in Path,
      join: up in UserPath,
      on: up.path_id == p.id,
      where: up.user_id == ^user_id,
      where: p.full_path == ^full_path
    )
    |> Repo.one()
  end

  @doc """
  Creates a path and associates it with a user.

  If a path with the same full_path exists and is soft-deleted, it will be restored
  instead of creating a new record. The restored path will have mount_point set to false.

  Attrs must include:
  - user_id: The user who will own this path (owner role)
  - path: The path segment
  - parent_id: (optional) The parent path ID

  ## Examples

      iex> create_path(%{path: "xyz", user_id: user_id})
      {:ok, %Path{}}

      iex> create_path(%{path: ""})
      {:error, %Ecto.Changeset{}}

  """
  def create_path(attrs \\ %{}) do
    # Extract user_id from attrs before validating path changeset
    user_id = Map.get(attrs, :user_id) || Map.get(attrs, "user_id")

    # First, validate the changeset
    changeset = Path.create_changeset(%Path{}, attrs)

    if changeset.valid? && user_id do
      # Wrap in transaction with row-level locking to prevent race conditions
      Repo.transaction(fn ->
        path_segment = Ecto.Changeset.get_field(changeset, :path)
        parent_id = Ecto.Changeset.get_field(changeset, :parent_id)

        # Lock any matching soft-deleted row to prevent concurrent restoration
        query =
          from p in Path,
            where: p.path == ^path_segment,
            where: not is_nil(p.deleted_at),
            lock: "FOR UPDATE"

        query =
          if is_nil(parent_id) do
            where(query, [p], is_nil(p.parent_id))
          else
            where(query, [p], p.parent_id == ^parent_id)
          end

        case Repo.one(query) do
          nil ->
            # No soft-deleted path exists, create new
            case Repo.insert(changeset) do
              {:ok, path} ->
                # Create user_path association with owner role
                user_path_attrs = %{
                  user_id: user_id,
                  path_id: path.id,
                  role: "owner"
                }

                case UserPath.changeset(%UserPath{}, user_path_attrs) |> Repo.insert() do
                  {:ok, _user_path} ->
                    Repo.get!(Path, path.id)

                  {:error, changeset} ->
                    Repo.rollback(changeset)
                end

              {:error, changeset} ->
                Repo.rollback(changeset)
            end

          path ->
            # Restore the soft-deleted path
            case Path.restore_changeset(path, attrs) |> Repo.update() do
              {:ok, path} ->
                # Check if user_path association already exists
                existing_user_path =
                  Repo.get_by(UserPath, user_id: user_id, path_id: path.id)

                if existing_user_path do
                  # User path already exists, just return the path
                  Repo.get!(Path, path.id)
                else
                  # Create new user_path association with owner role
                  user_path_attrs = %{
                    user_id: user_id,
                    path_id: path.id,
                    role: "owner"
                  }

                  case UserPath.changeset(%UserPath{}, user_path_attrs) |> Repo.insert() do
                    {:ok, _user_path} ->
                      Repo.get!(Path, path.id)

                    {:error, changeset} ->
                      Repo.rollback(changeset)
                  end
                end

              {:error, changeset} ->
                Repo.rollback(changeset)
            end
        end
      end)
    else
      if user_id do
        {:error, changeset}
      else
        {:error,
         Path.create_changeset(%Path{}, attrs)
         |> Ecto.Changeset.add_error(:user_id, "can't be blank")}
      end
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

    # Execute with explicit timeout and log cascade operations
    result = Repo.query!(query, [uuid_binary, deleted_at], timeout: 30_000)

    if result.num_rows > 0 do
      require Logger
      Logger.info("Cascade soft-deleted #{result.num_rows} descendant paths for path #{path.id}")
    end

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

  # User-Path Association Management

  @doc """
  Associates a user with a path with a specific role.

  ## Examples

      iex> add_user_to_path(user_id, path_id, "viewer")
      {:ok, %UserPath{}}

  """
  def add_user_to_path(user_id, path_id, role) do
    %UserPath{}
    |> UserPath.changeset(%{user_id: user_id, path_id: path_id, role: role})
    |> Repo.insert()
  end

  @doc """
  Updates a user's role for a path.

  ## Examples

      iex> update_user_path_role(user_path, "maintainer")
      {:ok, %UserPath{}}

  """
  def update_user_path_role(%UserPath{} = user_path, role) do
    user_path
    |> UserPath.changeset(%{role: role})
    |> Repo.update()
  end

  @doc """
  Removes a user's association with a path.

  ## Examples

      iex> remove_user_from_path(user_path)
      {:ok, %UserPath{}}

  """
  def remove_user_from_path(%UserPath{} = user_path) do
    Repo.delete(user_path)
  end

  @doc """
  Gets a user_path association by user_id and path_id.

  ## Examples

      iex> get_user_path(user_id, path_id)
      %UserPath{}

  """
  def get_user_path(user_id, path_id) do
    Repo.get_by(UserPath, user_id: user_id, path_id: path_id)
  end

  @doc """
  Lists all users associated with a path.

  ## Examples

      iex> list_path_users(path_id)
      [%UserPath{}, ...]

  """
  def list_path_users(path_id) do
    UserPath
    |> where([up], up.path_id == ^path_id)
    |> Repo.all()
    |> Repo.preload(:user)
  end

  @doc """
  Checks if a user has a specific role for a path.

  ## Examples

      iex> has_role?(user_id, path_id, "owner")
      true

  """
  def has_role?(user_id, path_id, role) do
    UserPath
    |> where([up], up.user_id == ^user_id)
    |> where([up], up.path_id == ^path_id)
    |> where([up], up.role == ^role)
    |> Repo.exists?()
  end

  @doc """
  Checks if a path can be marked as a mount point.

  Returns true if it can be marked as mount, false if it has children.

  ## Examples

      iex> can_mark_as_mount?(path)
      true

      iex> can_mark_as_mount?(path_with_children)
      false

  """
  def can_mark_as_mount?(%Path{} = path) do
    child_count =
      Path
      |> where([p], p.parent_id == ^path.id)
      |> where([p], is_nil(p.deleted_at))
      |> Repo.aggregate(:count)

    child_count == 0
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
      SELECT id, parent_id, path, full_path,
             mount_point, inserted_at, updated_at, deleted_at
      FROM paths
      WHERE parent_id = $1
        AND deleted_at IS NULL

      UNION ALL

      SELECT p.id, p.parent_id, p.path, p.full_path,
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
    result = Repo.query!(query, [uuid_binary], timeout: 30_000)

    Enum.map(result.rows, fn row ->
      Repo.load(Path, {result.columns, row})
    end)
  end
end
