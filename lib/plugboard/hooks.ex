defmodule Plugboard.Hooks do
  @moduledoc """
  Context for managing hooks - middleware that processes requests before reaching backends.

  Hooks execute sequentially and can:
  - Call internal mount points (via telephone)
  - Call external HTTP endpoints
  - Merge their responses into the request body
  - Reject requests based on status codes
  """

  import Ecto.Query

  alias Plugboard.Hooks.Hook
  alias Plugboard.Paths
  alias Plugboard.Repo

  @doc """
  Lists all active hooks for a given path, ordered by execution_order.

  ## Examples

      iex> list_hooks_for_path(path_id)
      [%Hook{}, ...]
  """
  def list_hooks_for_path(path_id) do
    Hook
    |> where([h], h.path_id == ^path_id and is_nil(h.deleted_at))
    |> order_by([h], asc: h.execution_order)
    |> preload([:target_path])
    |> Repo.all()
  end

  @doc """
  Gets a single hook by ID.

  Returns `nil` if the hook does not exist or is soft-deleted.

  ## Examples

      iex> get_hook(id)
      %Hook{}

      iex> get_hook("nonexistent")
      nil
  """
  def get_hook(id) do
    Hook
    |> where([h], h.id == ^id and is_nil(h.deleted_at))
    |> preload([:path, :target_path])
    |> Repo.one()
  end

  @doc """
  Creates a hook.

  Validates:
  - User has owner or maintainer role on the path
  - Target path exists and is a mount point (if target_type = mount_point)
  - No circular dependency exists
  - Execution order is unique for the path

  ## Examples

      iex> create_hook(user_id, %{name: "Auth Hook", ...})
      {:ok, %Hook{}}

      iex> create_hook(user_id, %{name: ""})
      {:error, %Ecto.Changeset{}}
  """
  def create_hook(user_id, attrs) do
    path_id = Map.get(attrs, :path_id) || Map.get(attrs, "path_id")

    # Check user has permission
    case Paths.get_user_role(user_id, path_id) do
      role when role in ["owner", "maintainer"] ->
        do_create_hook(attrs)

      "viewer" ->
        {:error, "Requires owner or maintainer role"}

      nil ->
        {:error, "You do not have access to this path"}
    end
  end

  @doc """
  Updates a hook.

  ## Examples

      iex> update_hook(user_id, hook, %{name: "New Name"})
      {:ok, %Hook{}}

      iex> update_hook(user_id, hook, %{name: ""})
      {:error, %Ecto.Changeset{}}
  """
  def update_hook(user_id, %Hook{} = hook, attrs) do
    # Check user has permission on the hook's path
    case Paths.get_user_role(user_id, hook.path_id) do
      role when role in ["owner", "maintainer"] ->
        do_update_hook(hook, attrs)

      "viewer" ->
        {:error, "Requires owner or maintainer role"}

      nil ->
        {:error, "You do not have access to this path"}
    end
  end

  @doc """
  Soft-deletes a hook.

  ## Examples

      iex> delete_hook(user_id, hook)
      {:ok, %Hook{}}
  """
  def delete_hook(user_id, %Hook{} = hook) do
    # Check user has permission
    case Paths.get_user_role(user_id, hook.path_id) do
      role when role in ["owner", "maintainer"] ->
        hook
        |> Hook.delete_changeset()
        |> Repo.update()
        |> case do
          {:ok, deleted_hook} ->
            # Emit telemetry
            :telemetry.execute(
              [:plugboard, :hook, :deleted],
              %{count: 1},
              %{hook_id: hook.id, path_id: hook.path_id}
            )

            {:ok, deleted_hook}

          error ->
            error
        end

      "viewer" ->
        {:error, "Requires owner or maintainer role"}

      nil ->
        {:error, "You do not have access to this path"}
    end
  end

  @doc """
  Reorders hooks for a path by updating execution_order values.

  Expects a list of maps with %{id: hook_id, execution_order: new_order}.

  ## Examples

      iex> reorder_hooks(user_id, path_id, [%{id: "hook1", execution_order: 0}, ...])
      {:ok, [%Hook{}, ...]}
  """
  def reorder_hooks(user_id, path_id, hook_orders) when is_list(hook_orders) do
    # Check user has permission
    case Paths.get_user_role(user_id, path_id) do
      role when role in ["owner", "maintainer"] ->
        do_reorder_hooks(path_id, hook_orders)

      "viewer" ->
        {:error, "Requires owner or maintainer role"}

      nil ->
        {:error, "You do not have access to this path"}
    end
  end

  ## Private functions

  defp do_create_hook(attrs) do
    Repo.transaction(fn ->
      changeset = Hook.create_changeset(%Hook{}, attrs)

      with :ok <- validate_changeset(changeset),
           :ok <- validate_hook_target(changeset) do
        insert_hook(changeset)
      else
        {:error, reason} -> Repo.rollback(reason)
        {:invalid, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  defp validate_changeset(changeset) do
    if changeset.valid?, do: :ok, else: {:invalid, changeset}
  end

  defp validate_hook_target(changeset) do
    target_type = Ecto.Changeset.get_field(changeset, :target_type)

    if target_type == "mount_point" do
      target_path_id = Ecto.Changeset.get_field(changeset, :target_path_id)
      path_id = Ecto.Changeset.get_field(changeset, :path_id)

      with :ok <- validate_mount_point_target(target_path_id) do
        check_circular_dependency(path_id, target_path_id)
      end
    else
      # HTTP URL target - no additional validation needed
      :ok
    end
  end

  defp validate_mount_point_target(target_path_id) do
    case Paths.get_path(target_path_id) do
      nil ->
        {:error, "Target path not found"}

      path ->
        cond do
          path.deleted_at != nil ->
            {:error, "Target path is deleted"}

          not path.mount_point ->
            {:error, "Target path must be a mount point"}

          true ->
            :ok
        end
    end
  end

  # Detects circular dependency by checking if target_path_id has any hooks
  # that would eventually call back to source_path_id.
  #
  # Algorithm:
  # 1. Start with target_path_id
  # 2. Get all its hooks
  # 3. For each hook with target_type = mount_point:
  #    - If target points to source_path_id → circular dependency!
  #    - Otherwise, recursively check that target's hooks
  # 4. Track visited paths to prevent infinite loops
  defp check_circular_dependency(source_path_id, target_path_id) do
    check_circular_recursive(source_path_id, target_path_id, MapSet.new())
  end

  defp check_circular_recursive(source_path_id, current_path_id, visited) do
    # If we've already visited this path, stop (prevents infinite loops)
    if MapSet.member?(visited, current_path_id) do
      :ok
    else
      # Mark this path as visited
      visited = MapSet.put(visited, current_path_id)

      # Get all hooks for current_path_id
      hooks =
        Hook
        |> where([h], h.path_id == ^current_path_id and is_nil(h.deleted_at))
        |> where([h], h.target_type == "mount_point")
        |> Repo.all()

      # Check each hook's target
      Enum.reduce_while(hooks, :ok, fn hook, :ok ->
        # Direct circular dependency
        if hook.target_path_id == source_path_id do
          {:halt, {:error, "Circular dependency detected: hook would create an infinite loop"}}
        else
          # Recursive check
          case check_circular_recursive(source_path_id, hook.target_path_id, visited) do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end
        end
      end)
    end
  end

  defp insert_hook(changeset) do
    case Repo.insert(changeset) do
      {:ok, hook} ->
        # Emit telemetry
        :telemetry.execute(
          [:plugboard, :hook, :created],
          %{count: 1},
          %{hook_id: hook.id, path_id: hook.path_id, target_type: hook.target_type}
        )

        # Reload with preloads
        Repo.get!(Hook, hook.id) |> Repo.preload([:path, :target_path])

      {:error, changeset} ->
        Repo.rollback(changeset)
    end
  end

  defp do_update_hook(hook, attrs) do
    Repo.transaction(fn ->
      changeset = Hook.update_changeset(hook, attrs)

      with :ok <- validate_changeset(changeset),
           :ok <- validate_updated_hook_target(hook, changeset) do
        update_hook_record(hook, changeset)
      else
        {:error, reason} -> Repo.rollback(reason)
        {:invalid, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  defp validate_updated_hook_target(hook, changeset) do
    target_type = Ecto.Changeset.get_field(changeset, :target_type)
    target_type_changed = Ecto.Changeset.changed?(changeset, :target_type)
    target_path_changed = Ecto.Changeset.changed?(changeset, :target_path_id)

    # Re-validate only if target changed and type is mount_point
    if (target_type_changed or target_path_changed) and target_type == "mount_point" do
      target_path_id = Ecto.Changeset.get_field(changeset, :target_path_id)

      with :ok <- validate_mount_point_target(target_path_id) do
        check_circular_dependency(hook.path_id, target_path_id)
      end
    else
      :ok
    end
  end

  defp update_hook_record(hook, changeset) do
    case Repo.update(changeset) do
      {:ok, updated_hook} ->
        # Emit telemetry
        :telemetry.execute(
          [:plugboard, :hook, :updated],
          %{count: 1},
          %{hook_id: hook.id, path_id: hook.path_id}
        )

        # Reload with preloads
        Repo.get!(Hook, updated_hook.id) |> Repo.preload([:path, :target_path])

      {:error, changeset} ->
        Repo.rollback(changeset)
    end
  end

  defp do_reorder_hooks(path_id, hook_orders) do
    Repo.transaction(fn ->
      hook_ids = Enum.map(hook_orders, & &1.id)

      case fetch_hooks_for_reorder(path_id, hook_ids) do
        {:ok, hooks} ->
          updated_hooks = update_hook_orders(hooks, hook_orders)
          emit_reorder_telemetry(path_id, updated_hooks)
          updated_hooks

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  defp fetch_hooks_for_reorder(path_id, hook_ids) do
    hooks =
      Hook
      |> where([h], h.id in ^hook_ids and h.path_id == ^path_id and is_nil(h.deleted_at))
      |> Repo.all()

    if length(hooks) == length(hook_ids) do
      {:ok, hooks}
    else
      {:error, "Some hooks not found or do not belong to this path"}
    end
  end

  defp update_hook_orders(hooks, hook_orders) do
    Enum.map(hook_orders, fn %{id: hook_id, execution_order: new_order} ->
      hook = Enum.find(hooks, &(&1.id == hook_id))

      case Repo.update(Ecto.Changeset.change(hook, execution_order: new_order)) do
        {:ok, updated} -> updated
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  defp emit_reorder_telemetry(path_id, updated_hooks) do
    :telemetry.execute(
      [:plugboard, :hook, :reordered],
      %{count: length(updated_hooks)},
      %{path_id: path_id}
    )
  end
end
