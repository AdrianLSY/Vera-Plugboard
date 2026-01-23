defmodule PlugboardWeb.Api.ServiceAccountController do
  @moduledoc """
  API controller for managing service accounts.

  Allows users with owner or maintainer roles to create and manage
  service accounts for programmatic token generation.
  """

  use PlugboardWeb, :controller

  alias Plugboard.Paths
  alias Plugboard.ServiceAccounts

  @doc """
  Creates a new service account for a path.

  Requires the authenticated user to have owner or maintainer role on the path.
  """
  def create(conn, %{"path_id" => path_id} = params) do
    user = conn.assigns.current_scope.user
    name = Map.get(params, "name")
    description = Map.get(params, "description")

    # Validate required parameters
    if is_nil(name) || String.trim(name) == "" do
      conn
      |> put_status(:bad_request)
      |> json(%{error: "Name is required"})
    else
      case ServiceAccounts.generate_service_account(user, path_id, name, description) do
        {:ok, api_key, service_account} ->
          conn
          |> put_status(:created)
          |> json(%{
            api_key: api_key,
            id: service_account.id,
            name: service_account.name,
            description: service_account.description,
            path_id: service_account.path_id,
            created_at: service_account.inserted_at,
            message: "Store this API key securely. It cannot be retrieved again."
          })

        {:error, reason} when is_binary(reason) ->
          conn
          |> put_status(:forbidden)
          |> json(%{error: reason})

        {:error, %Ecto.Changeset{} = changeset} ->
          errors = translate_changeset_errors(changeset)

          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: "Failed to create service account", details: errors})
      end
    end
  end

  @doc """
  Lists all service accounts for a given path.
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
        service_accounts = ServiceAccounts.list_service_accounts_for_path(path_id)

        # Don't return API key hashes, just metadata
        service_accounts_data =
          Enum.map(service_accounts, fn sa ->
            %{
              id: sa.id,
              name: sa.name,
              description: sa.description,
              last_used_at: sa.last_used_at,
              created_at: sa.inserted_at
            }
          end)

        json(conn, %{service_accounts: service_accounts_data})
    end
  end

  @doc """
  Lists all service accounts for the authenticated user.
  """
  def index_for_user(conn, _params) do
    user = conn.assigns.current_scope.user
    service_accounts = ServiceAccounts.list_service_accounts_for_user(user.id)

    service_accounts_data =
      Enum.map(service_accounts, fn sa ->
        %{
          id: sa.id,
          name: sa.name,
          description: sa.description,
          path_id: sa.path_id,
          path: sa.path.full_path,
          last_used_at: sa.last_used_at,
          created_at: sa.inserted_at
        }
      end)

    json(conn, %{service_accounts: service_accounts_data})
  end

  @doc """
  Revokes a service account.

  Requires owner or maintainer role on the associated path.
  """
  def delete(conn, %{"id" => service_account_id}) do
    user = conn.assigns.current_scope.user

    case ServiceAccounts.get_service_account(service_account_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Service account not found"})

      _service_account ->
        case ServiceAccounts.revoke_service_account(user.id, service_account_id) do
          {:ok, _revoked_sa} ->
            conn
            |> put_status(:ok)
            |> json(%{message: "Service account revoked successfully"})

          {:error, :unauthorized} ->
            conn
            |> put_status(:forbidden)
            |> json(%{error: "Requires owner or maintainer role"})

          {:error, changeset} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: "Failed to revoke service account", details: changeset})
        end
    end
  end

  # Private functions

  defp translate_changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
