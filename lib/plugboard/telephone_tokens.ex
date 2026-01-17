defmodule Plugboard.TelephoneTokens do
  @moduledoc """
  Context for managing telephone authentication tokens.

  Telephone tokens are JWT-based credentials that allow backend servers
  to connect to Plugboard and serve HTTP traffic for a specific path.
  """

  import Ecto.Query, warn: false

  alias Plugboard.Crypto
  alias Plugboard.Paths
  alias Plugboard.Paths.Path
  alias Plugboard.Repo
  alias Plugboard.TelephoneTokens.TelephoneToken

  require Logger

  @doc """
  Generates a new JWT token for a telephone to connect to a specific path.

  ## Parameters
    - path: The path this token grants access to (must be a mount point)
    - user: The user creating the token (must have owner or maintainer role)
    - name: Optional name for the token
    - description: Optional description for the token

  ## Returns
    - {:ok, jwt_string, token} on success
    - {:error, reason} on failure
  """
  def generate_token(%Path{} = path, user, name \\ nil, description \\ nil) do
    # Check user has permission on the path
    case Paths.get_user_role(user.id, path.id) do
      role when role in ["owner", "maintainer"] ->
        # Validate path is a mount point
        cond do
          not path.mount_point ->
            {:error, "Path must be a mount point"}

          not is_nil(path.deleted_at) ->
            {:error, "Path is deleted"}

          true ->
            do_generate_token(path, user, name, description)
        end

      "viewer" ->
        {:error, :unauthorized}

      nil ->
        {:error, :unauthorized}
    end
  end

  defp do_generate_token(path, user, name, description) do
    # Get token expiry from config
    expiry_seconds = Application.get_env(:plugboard, :telephone)[:token_expiry] || 3600
    expires_at = DateTime.utc_now() |> DateTime.add(expiry_seconds, :second)

    # Generate JWT
    claims = %{
      "sub" => user.id,
      "jti" => Ecto.UUID.generate(),
      "path_id" => path.id,
      "iat" => DateTime.utc_now() |> DateTime.to_unix(),
      "exp" => expires_at |> DateTime.to_unix()
    }

    case generate_jwt(claims) do
      {:ok, jwt} ->
        # Hash the JWT for storage
        token_hash = hash_token(jwt)

        # Create token record
        attrs = %{
          path_id: path.id,
          user_id: user.id,
          token_hash: token_hash,
          name: name,
          description: description,
          expires_at: expires_at
        }

        case create_token(attrs) do
          {:ok, token} ->
            # Emit telemetry for token creation
            :telemetry.execute(
              [:plugboard, :telephone_token, :created],
              %{count: 1},
              %{path_id: path.id, user_id: user.id}
            )

            {:ok, jwt, token}

          {:error, changeset} ->
            {:error, changeset}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Validates a JWT token and returns the associated token record and path.

  ## Parameters
    - jwt_string: The JWT to validate

  ## Returns
    - {:ok, %{token: token, path: path, user_id: user_id}} on success
    - {:error, reason} on failure
  """
  def validate_jwt(jwt_string) when is_binary(jwt_string) do
    with {:ok, claims} <- verify_jwt(jwt_string),
         {:ok, token} <- find_token_by_jwt(jwt_string),
         :ok <- validate_token_active(token),
         {:ok, path} <- validate_path(claims["path_id"]) do
      {:ok, %{token: token, path: path, user_id: claims["sub"]}}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def validate_jwt(_), do: {:error, "Invalid token format"}

  @doc """
  Validates a JWT token and marks it as used in a single transaction.

  This prevents race conditions where a token could be revoked between
  validation and marking as used.

  ## Parameters
    - jwt_string: The JWT to validate

  ## Returns
    - {:ok, %{token: token, path: path, user_id: user_id}} on success
    - {:error, reason} on failure
  """
  def validate_and_mark_used(jwt_string) when is_binary(jwt_string) do
    Repo.transaction(fn ->
      with {:ok, claims} <- verify_jwt(jwt_string),
           {:ok, token} <- find_token_by_jwt(jwt_string),
           :ok <- validate_token_active(token),
           {:ok, path} <- validate_path(claims["path_id"]),
           {:ok, _updated_token} <- mark_token_used(token.id) do
        # Emit telemetry for successful validation
        :telemetry.execute(
          [:plugboard, :telephone_token, :validated],
          %{count: 1},
          %{path_id: claims["path_id"], user_id: claims["sub"]}
        )

        %{token: token, path: path, user_id: claims["sub"]}
      else
        {:error, reason} ->
          # Emit telemetry for validation failure
          :telemetry.execute(
            [:plugboard, :telephone_token, :validation_failed],
            %{count: 1},
            %{reason: reason}
          )

          Repo.rollback(reason)
      end
    end)
  end

  def validate_and_mark_used(_), do: {:error, "Invalid token format"}

  @doc """
  Revokes a token, preventing it from being used for future connections.

  Requires owner or maintainer role on the path.
  """
  def revoke_token(user_id, token_id) do
    case get_token(token_id) do
      nil ->
        {:error, :not_found}

      token ->
        # Check user has permission on the path
        case Paths.get_user_role(user_id, token.path_id) do
          role when role in ["owner", "maintainer"] ->
            result =
              token
              |> TelephoneToken.revoke_changeset()
              |> Repo.update()

            case result do
              {:ok, revoked_token} ->
                # Emit telemetry for token revocation
                :telemetry.execute(
                  [:plugboard, :telephone_token, :revoked],
                  %{count: 1},
                  %{token_id: token_id, path_id: token.path_id}
                )

                {:ok, revoked_token}

              error ->
                error
            end

          _role ->
            {:error, :unauthorized}
        end
    end
  end

  @doc """
  Refreshes a token by generating a new JWT with extended expiry.

  ## Returns
    - {:ok, new_jwt, expires_in_seconds} on success
    - {:error, reason} on failure
  """
  def refresh_token(token_id) do
    case get_token(token_id) do
      nil ->
        {:error, :not_found}

      token ->
        # Check if token is revoked
        if token.revoked_at do
          {:error, :token_revoked}
        else
          # Get expiry from config
          expiry_seconds = Application.get_env(:plugboard, :telephone)[:token_expiry] || 3600
          new_expires_at = DateTime.utc_now() |> DateTime.add(expiry_seconds, :second)

          # Generate new JWT with same claims but new expiry
          claims = %{
            "sub" => token.user_id,
            "jti" => token.id,
            "path_id" => token.path_id,
            "iat" => DateTime.utc_now() |> DateTime.to_unix(),
            "exp" => new_expires_at |> DateTime.to_unix()
          }

          case generate_jwt(claims) do
            {:ok, new_jwt} ->
              new_token_hash = hash_token(new_jwt)

              # Update token record
              token
              |> TelephoneToken.refresh_changeset(new_expires_at, new_token_hash)
              |> Repo.update()
              |> case do
                {:ok, _updated_token} ->
                  # Emit telemetry for token refresh
                  :telemetry.execute(
                    [:plugboard, :telephone_token, :refreshed],
                    %{count: 1},
                    %{token_id: token_id, path_id: token.path_id}
                  )

                  {:ok, new_jwt, expiry_seconds}

                {:error, changeset} ->
                  {:error, changeset}
              end

            {:error, reason} ->
              {:error, reason}
          end
        end
    end
  end

  @doc """
  Updates the last_used_at timestamp for a token.

  This function can be called standalone or within a transaction.
  """
  def mark_token_used(token_id) do
    case get_token(token_id) do
      nil ->
        {:error, :not_found}

      token ->
        token
        |> TelephoneToken.mark_used_changeset()
        |> Repo.update()
    end
  end

  @doc """
  Lists all active tokens for a given path.
  """
  def list_tokens_for_path(path_id) do
    TelephoneToken
    |> where([t], t.path_id == ^path_id)
    |> where([t], is_nil(t.revoked_at))
    |> order_by([t], desc: t.inserted_at)
    |> Repo.all()
  end

  @doc """
  Lists all tokens for a given user.
  """
  def list_tokens_for_user(user_id) do
    TelephoneToken
    |> where([t], t.user_id == ^user_id)
    |> where([t], is_nil(t.revoked_at))
    |> order_by([t], desc: t.inserted_at)
    |> preload(:path)
    |> Repo.all()
  end

  @doc """
  Deletes expired tokens (cleanup job).

  Returns `{:ok, count}` on success or `{:error, reason}` on failure.
  """
  @spec delete_expired_tokens() :: {:ok, non_neg_integer()} | {:error, term()}
  def delete_expired_tokens do
    now = DateTime.utc_now()

    {count, _} =
      TelephoneToken
      |> where([t], t.expires_at < ^now)
      |> Repo.delete_all()

    # Emit telemetry for cleanup
    :telemetry.execute(
      [:plugboard, :telephone_token, :cleanup],
      %{count: count},
      %{}
    )

    Logger.info("Deleted #{count} expired telephone tokens")
    {:ok, count}
  rescue
    e in Ecto.QueryError ->
      Logger.error("Failed to delete expired tokens: #{inspect(e)}")
      {:error, e}

    e in DBConnection.ConnectionError ->
      Logger.error("Database connection error during token cleanup: #{inspect(e)}")
      {:error, e}
  end

  @doc """
  Gets a single token by ID.
  """
  def get_token(token_id) do
    Repo.get(TelephoneToken, token_id)
  end

  @doc """
  Updates a token's name and description.

  ## Parameters
    - token_id: The ID of the token to update
    - attrs: Map with :name and/or :description keys

  ## Returns
    - {:ok, updated_token} on success
    - {:error, changeset} on validation failure
    - {:error, :not_found} if token doesn't exist
  """
  def update_token(token_id, attrs) do
    case get_token(token_id) do
      nil ->
        {:error, :not_found}

      token ->
        token
        |> TelephoneToken.update_changeset(attrs)
        |> Repo.update()
    end
  end

  ## Private functions

  defp create_token(attrs) do
    %TelephoneToken{}
    |> TelephoneToken.create_changeset(attrs)
    |> Repo.insert()
  end

  # Find token by verifying JWT against stored Argon2 hashes
  # This is necessary because Argon2 hashes include random salts,
  # so we can't do a direct hash lookup
  defp find_token_by_jwt(jwt_string) do
    # Get all active tokens (not revoked, not expired)
    # This is acceptable because:
    # 1. Active token count per path is typically small
    # 2. Argon2 verification is fast for correct tokens (early exit)
    # 3. Security benefit of salted hashes outweighs performance cost
    now = DateTime.utc_now()

    active_tokens =
      TelephoneToken
      |> where([t], is_nil(t.revoked_at))
      |> where([t], t.expires_at > ^now)
      |> Repo.all()

    # Find the token whose hash matches the JWT
    Enum.find_value(active_tokens, {:error, :token_not_found}, fn token ->
      if Crypto.verify_token(jwt_string, token.token_hash) do
        {:ok, token}
      else
        nil
      end
    end)
  end

  defp validate_token_active(token) do
    cond do
      token.revoked_at != nil ->
        {:error, :token_revoked}

      DateTime.compare(token.expires_at, DateTime.utc_now()) == :lt ->
        {:error, :token_expired}

      true ->
        :ok
    end
  end

  defp validate_path(path_id) do
    case Paths.get_path(path_id) do
      nil ->
        {:error, :path_not_found}

      path ->
        cond do
          path.deleted_at != nil ->
            {:error, :path_deleted}

          not path.mount_point ->
            {:error, :path_not_mount}

          true ->
            {:ok, path}
        end
    end
  end

  # JWT token generation and verification using Joken

  defp generate_jwt(claims) do
    secret = get_jwt_secret()
    signer = Joken.Signer.create("HS256", secret)

    token = Joken.generate_and_sign!(%{}, claims, signer)

    {:ok, token}
  rescue
    e ->
      Logger.error("Failed to generate JWT: #{inspect(e)}")
      {:error, :jwt_generation_failed}
  end

  defp verify_jwt(jwt_string) do
    secret = get_jwt_secret()

    case Joken.verify_and_validate(
           %{},
           jwt_string,
           Joken.Signer.create("HS256", secret)
         ) do
      {:ok, claims} ->
        {:ok, claims}

      {:error, reason} ->
        Logger.debug("JWT verification failed: #{inspect(reason)}")
        {:error, :invalid_token}
    end
  end

  defp get_jwt_secret do
    # Derive a separate key for JWT signing from the application secret
    # This ensures compromise of JWT key doesn't compromise other uses of secret_key_base
    Crypto.derive_jwt_secret("telephone_jwt")
  end

  defp hash_token(token) do
    # Use Argon2 for secure token hashing
    Crypto.hash_token(token)
  end
end
