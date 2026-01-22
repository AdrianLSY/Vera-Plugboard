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

    case ServiceAccounts.validate_and_mark_used(api_key) do
      {:ok, %{service_account: sa, path: path, user_id: user_id}} ->
        case verify_path_access(path_id, path) do
          :ok ->
            do_generate_token(conn, sa, path, user_id, params)

          {:error, :forbidden, details} ->
            conn
            |> put_status(:forbidden)
            |> json(details)
        end

      {:error, reason} ->
        Logger.warning("Token vending failed: #{inspect(reason)}")

        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Invalid or revoked service account API key"})
    end
  end

  defp verify_path_access(nil, _path), do: :ok
  defp verify_path_access(path_id, path) when path_id == path.id, do: :ok

  defp verify_path_access(path_id, path) do
    {:error, :forbidden,
     %{
       error: "Service account does not have access to this path",
       allowed_path_id: path.id,
       requested_path_id: path_id
     }}
  end

  defp do_generate_token(conn, sa, path, user_id, params) do
    description = Map.get(params, "description")
    instance_id = Map.get(params, "instance_id")
    {token_name, token_description} = build_token_metadata(sa, description, instance_id)

    user = Plugboard.Accounts.get_user!(user_id)

    case TelephoneTokens.generate_token(path, user, token_name, token_description) do
      {:ok, jwt, token} ->
        send_token_response(conn, jwt, token, path, sa)

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

  defp build_token_metadata(sa, nil, nil), do: {"Auto-generated for #{sa.name}", nil}
  defp build_token_metadata(_sa, desc, nil), do: {desc, nil}
  defp build_token_metadata(sa, nil, inst_id), do: {"#{sa.name} - #{inst_id}", nil}
  defp build_token_metadata(_sa, desc, inst_id), do: {"#{inst_id}", desc}

  defp send_token_response(conn, jwt, token, path, sa) do
    expiry_seconds = Application.get_env(:plugboard, :telephone)[:token_expiry] || 3600

    Logger.info("Token vended for service account #{sa.name} (#{sa.id}), path #{path.full_path}")

    conn
    |> put_status(:created)
    |> json(%{
      token: jwt,
      token_id: token.id,
      path: path.full_path,
      expires_at: token.expires_at,
      expires_in: expiry_seconds
    })
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
