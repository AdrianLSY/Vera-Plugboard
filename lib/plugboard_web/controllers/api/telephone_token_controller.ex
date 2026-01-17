defmodule PlugboardWeb.Api.TelephoneTokenController do
  @moduledoc """
  API controller for managing telephone tokens.

  Allows users with owner or maintainer roles to create and manage
  JWT tokens for telephone authentication.
  """

  use PlugboardWeb, :controller
  require Logger

  alias Plugboard.Paths
  alias Plugboard.TelephoneTokens

  @doc """
  Creates a new telephone token for a path.

  Requires the authenticated user to have owner or maintainer role on the path.
  """
  def create(conn, %{"path_id" => path_id} = params) do
    user = conn.assigns.current_scope.user
    name = Map.get(params, "name")
    description = Map.get(params, "description")

    case Paths.get_path(path_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Path not found"})

      path ->
        # Check user has appropriate role
        case Paths.get_user_role(user.id, path_id) do
          role when role in ["owner", "maintainer"] ->
            create_token_for_path(conn, path, user, name, description)

          "viewer" ->
            conn
            |> put_status(:forbidden)
            |> json(%{error: "Requires owner or maintainer role"})

          nil ->
            conn
            |> put_status(:forbidden)
            |> json(%{error: "You do not have access to this path"})
        end
    end
  end

  @doc """
  Lists all tokens for a given path.
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
        tokens = TelephoneTokens.list_tokens_for_path(path_id)

        # Don't return token hashes, just metadata
        tokens_data =
          Enum.map(tokens, fn token ->
            %{
              id: token.id,
              name: token.name,
              description: token.description,
              expires_at: token.expires_at,
              last_used_at: token.last_used_at,
              created_at: token.inserted_at
            }
          end)

        json(conn, %{tokens: tokens_data})
    end
  end

  @doc """
  Revokes a token.

  Requires owner or maintainer role on the associated path.
  """
  def delete(conn, %{"id" => token_id}) do
    user = conn.assigns.current_scope.user

    case TelephoneTokens.get_token(token_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Token not found"})

      _token ->
        case TelephoneTokens.revoke_token(user.id, token_id) do
          {:ok, _revoked_token} ->
            Logger.info("Token #{token_id} revoked by user #{user.id}")

            conn
            |> put_status(:ok)
            |> json(%{message: "Token revoked successfully"})

          {:error, :unauthorized} ->
            conn
            |> put_status(:forbidden)
            |> json(%{error: "Requires owner or maintainer role"})

          {:error, changeset} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: "Failed to revoke token", details: changeset})
        end
    end
  end

  # Private functions

  defp create_token_for_path(conn, path, user, name, description) do
    case TelephoneTokens.generate_token(path, user, name, description) do
      {:ok, jwt, token} ->
        Logger.info("Token created for path #{path.full_path} by user #{user.id}")

        conn
        |> put_status(:created)
        |> json(%{
          token: jwt,
          id: token.id,
          path: path.full_path,
          expires_at: token.expires_at,
          name: token.name,
          description: token.description,
          message: "Store this token securely. It cannot be retrieved again."
        })

      {:error, reason} when is_binary(reason) ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: reason})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Failed to create token", details: changeset})
    end
  end
end
