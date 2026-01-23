defmodule PlugboardWeb.Api.HookController do
  @moduledoc """
  API controller for managing hooks.

  Allows users with owner or maintainer roles to create and manage
  hooks for request preprocessing.
  """

  use PlugboardWeb, :controller

  alias Plugboard.Hooks
  alias Plugboard.Paths

  @doc """
  Creates a new hook for a path.

  Requires the authenticated user to have owner or maintainer role on the path.
  """
  def create(conn, %{"path_id" => path_id} = params) do
    user = conn.assigns.current_scope.user

    case Paths.get_path(path_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Path not found"})

      _path ->
        # Build attrs from params
        attrs = %{
          path_id: path_id,
          name: Map.get(params, "name"),
          description: Map.get(params, "description"),
          target_type: Map.get(params, "target_type", "mount_point"),
          target_path_id: Map.get(params, "target_path_id"),
          target_url: Map.get(params, "target_url"),
          execution_order: Map.get(params, "execution_order", 0),
          timeout_ms: Map.get(params, "timeout_ms", 5000),
          allowed_status_codes: Map.get(params, "allowed_status_codes", [200, 201, 202, 204]),
          forward_headers: Map.get(params, "forward_headers", []),
          forward_query_params: Map.get(params, "forward_query_params", false)
        }

        case Hooks.create_hook(user.id, attrs) do
          {:ok, hook} ->
            conn
            |> put_status(:created)
            |> json(%{
              id: hook.id,
              name: hook.name,
              description: hook.description,
              target_type: hook.target_type,
              target_path_id: hook.target_path_id,
              target_url: hook.target_url,
              execution_order: hook.execution_order,
              timeout_ms: hook.timeout_ms,
              allowed_status_codes: hook.allowed_status_codes,
              forward_headers: hook.forward_headers,
              forward_query_params: hook.forward_query_params,
              created_at: hook.inserted_at
            })

          {:error, reason} when is_binary(reason) ->
            conn
            |> put_status(:forbidden)
            |> json(%{error: reason})

          {:error, changeset} ->
            errors =
              Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)

            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: "Failed to create hook", details: errors})
        end
    end
  end

  @doc """
  Lists all hooks for a given path.
  """
  def index(conn, %{"path_id" => path_id}) do
    user = conn.assigns.current_scope.user

    # Check user has access to this path
    case Paths.get_user_role(user.id, path_id) do
      nil ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "You do not have access to this path"})

      _role ->
        hooks = Hooks.list_hooks_for_path(path_id)

        hooks_data =
          Enum.map(hooks, fn hook ->
            %{
              id: hook.id,
              name: hook.name,
              description: hook.description,
              target_type: hook.target_type,
              target_path_id: hook.target_path_id,
              target_path: if(hook.target_path, do: hook.target_path.full_path, else: nil),
              target_url: hook.target_url,
              execution_order: hook.execution_order,
              timeout_ms: hook.timeout_ms,
              allowed_status_codes: hook.allowed_status_codes,
              forward_headers: hook.forward_headers,
              forward_query_params: hook.forward_query_params,
              created_at: hook.inserted_at,
              updated_at: hook.updated_at
            }
          end)

        json(conn, %{hooks: hooks_data})
    end
  end

  @doc """
  Gets a single hook by ID.
  """
  def show(conn, %{"id" => hook_id}) do
    user = conn.assigns.current_scope.user

    case Hooks.get_hook(hook_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Hook not found"})

      hook ->
        # Check user has access to the path
        case Paths.get_user_role(user.id, hook.path_id) do
          nil ->
            conn
            |> put_status(:forbidden)
            |> json(%{error: "You do not have access to this hook"})

          _role ->
            json(conn, %{
              id: hook.id,
              path_id: hook.path_id,
              path: if(hook.path, do: hook.path.full_path, else: nil),
              name: hook.name,
              description: hook.description,
              target_type: hook.target_type,
              target_path_id: hook.target_path_id,
              target_path: if(hook.target_path, do: hook.target_path.full_path, else: nil),
              target_url: hook.target_url,
              execution_order: hook.execution_order,
              timeout_ms: hook.timeout_ms,
              allowed_status_codes: hook.allowed_status_codes,
              forward_headers: hook.forward_headers,
              forward_query_params: hook.forward_query_params,
              created_at: hook.inserted_at,
              updated_at: hook.updated_at
            })
        end
    end
  end

  @doc """
  Updates a hook.
  """
  def update(conn, %{"id" => hook_id} = params) do
    user = conn.assigns.current_scope.user

    case Hooks.get_hook(hook_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Hook not found"})

      hook ->
        attrs = sanitize_hook_params(params)

        case Hooks.update_hook(user.id, hook, attrs) do
          {:ok, updated_hook} ->
            json(conn, %{
              id: updated_hook.id,
              name: updated_hook.name,
              description: updated_hook.description,
              target_type: updated_hook.target_type,
              target_path_id: updated_hook.target_path_id,
              target_url: updated_hook.target_url,
              execution_order: updated_hook.execution_order,
              timeout_ms: updated_hook.timeout_ms,
              allowed_status_codes: updated_hook.allowed_status_codes,
              forward_headers: updated_hook.forward_headers,
              forward_query_params: updated_hook.forward_query_params,
              updated_at: updated_hook.updated_at
            })

          {:error, reason} when is_binary(reason) ->
            conn
            |> put_status(:forbidden)
            |> json(%{error: reason})

          {:error, changeset} ->
            errors =
              Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)

            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: "Failed to update hook", details: errors})
        end
    end
  end

  @doc """
  Deletes (soft-deletes) a hook.
  """
  def delete(conn, %{"id" => hook_id}) do
    user = conn.assigns.current_scope.user

    case Hooks.get_hook(hook_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Hook not found"})

      hook ->
        case Hooks.delete_hook(user.id, hook) do
          {:ok, _deleted_hook} ->
            conn
            |> put_status(:ok)
            |> json(%{message: "Hook deleted successfully"})

          {:error, reason} when is_binary(reason) ->
            conn
            |> put_status(:forbidden)
            |> json(%{error: reason})

          {:error, changeset} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: "Failed to delete hook", details: changeset})
        end
    end
  end

  @doc """
  Reorders hooks for a path.

  Expects params like:
  %{
    "hooks" => [
      %{"id" => "hook1-id", "execution_order" => 0},
      %{"id" => "hook2-id", "execution_order" => 1}
    ]
  }
  """
  def reorder(conn, %{"path_id" => path_id, "hooks" => hook_orders}) do
    user = conn.assigns.current_scope.user

    # Convert string keys to atoms
    hook_orders_attrs =
      Enum.map(hook_orders, fn hook ->
        %{
          id: Map.get(hook, "id"),
          execution_order: Map.get(hook, "execution_order")
        }
      end)

    case Hooks.reorder_hooks(user.id, path_id, hook_orders_attrs) do
      {:ok, updated_hooks} ->
        hooks_data =
          Enum.map(updated_hooks, fn hook ->
            %{
              id: hook.id,
              execution_order: hook.execution_order
            }
          end)

        json(conn, %{hooks: hooks_data})

      {:error, reason} when is_binary(reason) ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: reason})

      {:error, _changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Failed to reorder hooks"})
    end
  end

  # Safely convert string keys to atoms using a predefined whitelist
  # This prevents atom exhaustion attacks by only using known atoms
  @allowed_hook_keys %{
    "name" => :name,
    "description" => :description,
    "target_type" => :target_type,
    "target_path_id" => :target_path_id,
    "target_url" => :target_url,
    "execution_order" => :execution_order,
    "timeout_ms" => :timeout_ms,
    "allowed_status_codes" => :allowed_status_codes,
    "forward_headers" => :forward_headers,
    "forward_query_params" => :forward_query_params
  }

  defp sanitize_hook_params(params) do
    params
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      case Map.get(@allowed_hook_keys, key) do
        nil -> acc
        atom_key -> Map.put(acc, atom_key, value)
      end
    end)
  end
end
