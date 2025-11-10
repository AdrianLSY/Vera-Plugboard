defmodule PlugboardWeb.Api.TokenVendingController do
  @moduledoc """
  API controller for Token Vending Machine.

  Allows service accounts to programmatically generate telephone tokens
  for auto-scaling clusters. Service accounts authenticate using API keys.
  """

  use PlugboardWeb, :controller
  require Logger

  alias Plugboard.ServiceAccounts
  alias Plugboard.TelephoneTokens

  @doc """
  Generates a new telephone token using service account credentials.

  Requires valid service account API key in Authorization header.
  The service account must have access to the specified path.

  ## Request
  POST /api/token-vending/generate
  Headers: Authorization: Bearer sa_live_<api_key>
  Body: {
    "path_id": "uuid",
    "description": "optional description",
    "instance_id": "optional instance identifier"
  }

  ## Response
  {
    "token": "eyJ...",
    "token_id": "uuid",
    "path": "/api/myservice",
    "expires_at": "2025-11-05T10:00:00Z",
    "expires_in": 3600
  }
  """
  def generate(conn, params) do
    # Extract API key from Authorization header
    case get_api_key_from_header(conn) do
      {:ok, api_key} ->
        generate_with_api_key(conn, api_key, params)

      {:error, reason} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: reason})
    end
  end

  defp generate_with_api_key(conn, api_key, params) do
    path_id = Map.get(params, "path_id")
    description = Map.get(params, "description")
    instance_id = Map.get(params, "instance_id")

    # Validate API key and get service account
    case ServiceAccounts.validate_and_mark_used(api_key) do
      {:ok, %{service_account: sa, path: path, user_id: user_id}} ->
        # Verify the requested path_id matches the service account's path
        if path_id && path_id != path.id do
          conn
          |> put_status(:forbidden)
          |> json(%{
            error: "Service account does not have access to this path",
            allowed_path_id: path.id,
            requested_path_id: path_id
          })
        else
          # Generate name and description
          {token_name, token_description} =
            case {description, instance_id} do
              {nil, nil} ->
                {"Auto-generated for #{sa.name}", nil}

              {desc, nil} ->
                {desc, nil}

              {nil, inst_id} ->
                {"#{sa.name} - #{inst_id}", nil}

              {desc, inst_id} ->
                {"#{inst_id}", desc}
            end

          # Get user record for token generation
          user = Plugboard.Accounts.get_user!(user_id)

          # Generate token
          case TelephoneTokens.generate_token(path, user, token_name, token_description) do
            {:ok, jwt, token} ->
              expiry_seconds =
                Application.get_env(:plugboard, :telephone)[:token_expiry] || 3600

              Logger.info(
                "Token vended for service account #{sa.name} (#{sa.id}), path #{path.full_path}"
              )

              conn
              |> put_status(:created)
              |> json(%{
                token: jwt,
                token_id: token.id,
                path: path.full_path,
                expires_at: token.expires_at,
                expires_in: expiry_seconds
              })

            {:error, reason} when is_binary(reason) ->
              conn
              |> put_status(:unprocessable_entity)
              |> json(%{error: reason})

            {:error, changeset} ->
              conn
              |> put_status(:unprocessable_entity)
              |> json(%{error: "Failed to generate token", details: changeset})
          end
        end

      {:error, reason} ->
        Logger.warning("Token vending failed: #{inspect(reason)}")

        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Invalid or revoked service account API key"})
    end
  end

  # Private functions

  defp get_api_key_from_header(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> api_key] ->
        {:ok, api_key}

      ["bearer " <> api_key] ->
        {:ok, api_key}

      [] ->
        {:error, "Missing Authorization header"}

      _ ->
        {:error, "Invalid Authorization header format. Use: Bearer <api_key>"}
    end
  end
end
