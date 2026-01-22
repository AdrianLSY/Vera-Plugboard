defmodule PlugboardWeb.Api.DomainAffinityController do
  @moduledoc """
  API controller for managing domain affinities.

  Domain affinities map domains to mount points, enabling vanity URLs that
  bypass the `/call` prefix.
  """

  use PlugboardWeb, :controller
  require Logger

  alias Plugboard.DomainAffinities
  alias Plugboard.Paths

  @doc """
  Creates a new domain affinity for a path.

  Requires the user to have owner or maintainer role for the path.
  The path must be a mount point.
  """
  def create(conn, %{"path_id" => path_id, "domain_affinity" => domain_params}) do
    user = conn.assigns.current_scope.user

    # Verify path exists and is a mount point
    case Paths.get_path(path_id) do
      nil ->
        conn
        |> put_status(404)
        |> json(%{error: "Path not found"})

      path ->
        if path.mount_point do
          attrs = Map.put(domain_params, "path_id", path_id)

          case DomainAffinities.create_domain_affinity(user.id, attrs) do
            {:ok, domain_affinity} ->
              conn
              |> put_status(201)
              |> json(%{
                id: domain_affinity.id,
                domain: domain_affinity.domain,
                path_id: domain_affinity.path_id,
                inserted_at: domain_affinity.inserted_at
              })

            {:error, :unauthorized} ->
              conn
              |> put_status(403)
              |> json(%{error: "Requires owner or maintainer role"})

            {:error, changeset} ->
              conn
              |> put_status(422)
              |> json(%{
                error: "Validation failed",
                details: translate_changeset_errors(changeset)
              })
          end
        else
          conn
          |> put_status(400)
          |> json(%{error: "Path must be a mount point"})
        end
    end
  end

  @doc """
  Lists all domain affinities for a path.
  """
  def index(conn, %{"path_id" => path_id}) do
    user = conn.assigns.current_scope.user

    # Check user has access to the path
    case Paths.get_user_role(user.id, path_id) do
      nil ->
        conn
        |> put_status(403)
        |> json(%{error: "You do not have access to this path"})

      _role ->
        domain_affinities = DomainAffinities.list_domain_affinities_for_path(path_id)

        conn
        |> json(%{
          domain_affinities:
            Enum.map(domain_affinities, fn da ->
              %{
                id: da.id,
                domain: da.domain,
                path_id: da.path_id,
                inserted_at: da.inserted_at,
                updated_at: da.updated_at
              }
            end)
        })
    end
  end

  @doc """
  Deletes a domain affinity.

  Requires the user to have owner or maintainer role for the associated path.
  """
  def delete(conn, %{"id" => id}) do
    user = conn.assigns.current_scope.user

    case DomainAffinities.delete_domain_affinity(user.id, id) do
      {:ok, _domain_affinity} ->
        conn
        |> put_status(200)
        |> json(%{message: "Domain affinity deleted successfully"})

      {:error, :not_found} ->
        conn
        |> put_status(404)
        |> json(%{error: "Domain affinity not found"})

      {:error, :unauthorized} ->
        conn
        |> put_status(403)
        |> json(%{error: "Requires owner or maintainer role"})

      {:error, _reason} ->
        conn
        |> put_status(500)
        |> json(%{error: "Failed to delete domain affinity"})
    end
  end

  # Helper to translate changeset errors
  defp translate_changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
