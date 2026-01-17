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

  alias Plugboard.Paths.Path
  alias Plugboard.Paths.UserPath
  alias Plugboard.Repo

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

  Requires owner or maintainer role on the path.

  ## Examples

      iex> update_path(user_id, path, %{mount_point: true})
      {:ok, %Path{}}

      iex> update_path(user_id, path, %{path: ""})
      {:error, %Ecto.Changeset{}}

      iex> update_path(unauthorized_user_id, path, %{})
      {:error, :unauthorized}

  """
  def update_path(user_id, %Path{} = path, attrs) do
    case get_user_role(user_id, path.id) do
      role when role in ["owner", "maintainer"] ->
        do_update_path(path, attrs)

      "viewer" ->
        {:error, :unauthorized}

      nil ->
        {:error, :unauthorized}
    end
  end

  defp do_update_path(path, attrs) do
    result =
      Repo.transaction(fn ->
        case path
             |> Path.update_changeset(attrs)
             |> Repo.update() do
          {:ok, updated} ->
            # Reload to get trigger-computed full_path
            # Note: Database trigger handles NOTIFY automatically
            reloaded = Repo.get!(Path, updated.id)
            reloaded

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)

    case result do
      {:ok, path} -> {:ok, path}
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Soft-deletes a path by setting deleted_at timestamp.

  Children are also soft-deleted recursively.

  Requires owner role on the path.

  ## Examples

      iex> delete_path(user_id, path)
      {:ok, %Path{}}

      iex> delete_path(unauthorized_user_id, path)
      {:error, :unauthorized}

  """
  def delete_path(user_id, %Path{} = path) do
    case get_user_role(user_id, path.id) do
      "owner" ->
        do_delete_path(path)

      role when role in ["maintainer", "viewer"] ->
        {:error, :unauthorized}

      nil ->
        {:error, :unauthorized}
    end
  end

  defp do_delete_path(path) do
    deleted_at = DateTime.utc_now() |> DateTime.truncate(:second)

    result =
      Repo.transaction(fn ->
        # Soft-delete all descendants first (database trigger will handle NOTIFY)
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

          Logger.info(
            "Cascade soft-deleted #{result.num_rows} descendant paths for path #{path.id}"
          )
        end

        # Then soft-delete the path itself
        case path
             |> Path.delete_changeset()
             |> Repo.update() do
          {:ok, deleted_path} ->
            # Note: Database trigger handles NOTIFY automatically
            deleted_path

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)

    case result do
      {:ok, path} -> {:ok, path}
      {:error, error} -> {:error, error}
    end
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

  Requires the acting user to have owner role on the path.

  ## Parameters
    - acting_user_id: The user performing the action (must be owner)
    - user_id: The user to associate with the path
    - path_id: The path ID
    - role: The role to assign ("owner", "maintainer", "viewer")

  ## Examples

      iex> add_user_to_path(owner_id, user_id, path_id, "viewer")
      {:ok, %UserPath{}}

      iex> add_user_to_path(non_owner_id, user_id, path_id, "viewer")
      {:error, :unauthorized}

  """
  def add_user_to_path(acting_user_id, user_id, path_id, role) do
    case get_user_role(acting_user_id, path_id) do
      "owner" ->
        %UserPath{}
        |> UserPath.changeset(%{user_id: user_id, path_id: path_id, role: role})
        |> Repo.insert()

      _ ->
        {:error, :unauthorized}
    end
  end

  @doc """
  Updates a user's role for a path.

  Requires the acting user to have owner role on the path.

  ## Parameters
    - acting_user_id: The user performing the action (must be owner)
    - user_path: The UserPath to update
    - role: The new role

  ## Examples

      iex> update_user_path_role(owner_id, user_path, "maintainer")
      {:ok, %UserPath{}}

      iex> update_user_path_role(non_owner_id, user_path, "maintainer")
      {:error, :unauthorized}

  """
  def update_user_path_role(acting_user_id, %UserPath{} = user_path, role) do
    case get_user_role(acting_user_id, user_path.path_id) do
      "owner" ->
        user_path
        |> UserPath.changeset(%{role: role})
        |> Repo.update()

      _ ->
        {:error, :unauthorized}
    end
  end

  @doc """
  Removes a user's association with a path.

  Requires the acting user to have owner role on the path.

  ## Parameters
    - acting_user_id: The user performing the action (must be owner)
    - user_path: The UserPath to remove

  ## Examples

      iex> remove_user_from_path(owner_id, user_path)
      {:ok, %UserPath{}}

      iex> remove_user_from_path(non_owner_id, user_path)
      {:error, :unauthorized}

  """
  def remove_user_from_path(acting_user_id, %UserPath{} = user_path) do
    case get_user_role(acting_user_id, user_path.path_id) do
      "owner" ->
        Repo.delete(user_path)

      _ ->
        {:error, :unauthorized}
    end
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
  Gets a user's role for a specific path.

  Returns the role string ("owner", "maintainer", "viewer") or nil if no association exists.

  ## Examples

      iex> get_user_role(user_id, path_id)
      "owner"

      iex> get_user_role(user_id, nonexistent_path_id)
      nil

  """
  def get_user_role(user_id, path_id) do
    case get_user_path(user_id, path_id) do
      nil -> nil
      user_path -> user_path.role
    end
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
  Gets a path with all its ancestors in a single query using a recursive CTE.

  Returns a list of paths from root to the given path (inclusive),
  ordered by depth (root first). This is more efficient than recursive
  Elixir calls for building breadcrumbs.

  ## Examples

      iex> get_path_with_ancestors(path_id)
      [%Path{full_path: "/api"}, %Path{full_path: "/api/v1"}, %Path{full_path: "/api/v1/users"}]

      iex> get_path_with_ancestors(root_path_id)
      [%Path{full_path: "/root"}]

      iex> get_path_with_ancestors(nonexistent_id)
      []

  """
  def get_path_with_ancestors(path_id) do
    query = """
    WITH RECURSIVE ancestors AS (
      SELECT id, parent_id, path, full_path, mount_point,
             request_timeout_ms, connect_timeout_ms,
             inserted_at, updated_at, deleted_at,
             0 as depth
      FROM paths
      WHERE id = $1 AND deleted_at IS NULL

      UNION ALL

      SELECT p.id, p.parent_id, p.path, p.full_path, p.mount_point,
             p.request_timeout_ms, p.connect_timeout_ms,
             p.inserted_at, p.updated_at, p.deleted_at,
             a.depth + 1
      FROM paths p
      INNER JOIN ancestors a ON p.id = a.parent_id
      WHERE p.deleted_at IS NULL
    )
    SELECT id, parent_id, path, full_path, mount_point,
           request_timeout_ms, connect_timeout_ms,
           inserted_at, updated_at, deleted_at
    FROM ancestors
    ORDER BY depth DESC
    """

    {:ok, uuid_binary} = Ecto.UUID.dump(path_id)
    result = Repo.query!(query, [uuid_binary], timeout: 15_000)

    Enum.map(result.rows, fn row ->
      Repo.load(Path, {result.columns, row})
    end)
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

  # Private helpers
  # Note: NOTIFY is now handled by database trigger (notify_mount_change function)
  # See migration: 20251102153313_add_mount_notify_trigger.exs
end
