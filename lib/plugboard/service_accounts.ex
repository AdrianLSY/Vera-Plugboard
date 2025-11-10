defmodule Plugboard.ServiceAccounts do
  @moduledoc """
  Context for managing service accounts.

  Service accounts are used by the Token Vending Machine to allow
  programmatic generation of telephone tokens for auto-scaling clusters.
  """

  import Ecto.Query, warn: false
  alias Plugboard.Repo
  alias Plugboard.ServiceAccounts.ServiceAccount
  alias Plugboard.Paths

  require Logger

  @doc """
  Generates a new service account with API key.

  ## Parameters
    - user: The user creating the service account (must have owner or maintainer role on path)
    - path_id: The path this service account can generate tokens for
    - name: Unique name for this service account
    - description: Optional description

  ## Returns
    - {:ok, api_key_string, service_account} on success
    - {:error, reason} on failure
  """
  def generate_service_account(user, path_id, name, description \\ nil) do
    # Validate path exists and user has access
    case Paths.get_path(path_id) do
      nil ->
        {:error, "Path not found"}

      path ->
        # Check user has appropriate role
        case Paths.get_user_role(user.id, path_id) do
          role when role in ["owner", "maintainer"] ->
            do_generate_service_account(user, path, name, description)

          "viewer" ->
            {:error, "Requires owner or maintainer role"}

          nil ->
            {:error, "You do not have access to this path"}
        end
    end
  end

  defp do_generate_service_account(user, path, name, description) do
    # Generate secure API key
    api_key = generate_api_key()
    api_key_hash = hash_api_key(api_key)

    attrs = %{
      user_id: user.id,
      path_id: path.id,
      name: name,
      description: description,
      api_key_hash: api_key_hash
    }

    case create_service_account(attrs) do
      {:ok, service_account} ->
        # Emit telemetry
        :telemetry.execute(
          [:plugboard, :service_account, :created],
          %{count: 1},
          %{path_id: path.id, user_id: user.id}
        )

        {:ok, api_key, service_account}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Validates an API key and returns the associated service account and path.

  ## Parameters
    - api_key_string: The API key to validate

  ## Returns
    - {:ok, %{service_account: sa, path: path, user_id: user_id}} on success
    - {:error, reason} on failure
  """
  def validate_api_key(api_key_string) when is_binary(api_key_string) do
    api_key_hash = hash_api_key(api_key_string)

    with {:ok, service_account} <- get_service_account_by_api_key_hash(api_key_hash),
         :ok <- validate_service_account_active(service_account),
         {:ok, path} <- validate_path(service_account.path_id) do
      {:ok, %{service_account: service_account, path: path, user_id: service_account.user_id}}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def validate_api_key(_), do: {:error, "Invalid API key format"}

  @doc """
  Validates an API key and marks it as used in a single transaction.

  ## Parameters
    - api_key_string: The API key to validate

  ## Returns
    - {:ok, %{service_account: sa, path: path, user_id: user_id}} on success
    - {:error, reason} on failure
  """
  def validate_and_mark_used(api_key_string) when is_binary(api_key_string) do
    Repo.transaction(fn ->
      api_key_hash = hash_api_key(api_key_string)

      with {:ok, service_account} <- get_service_account_by_api_key_hash(api_key_hash),
           :ok <- validate_service_account_active(service_account),
           {:ok, path} <- validate_path(service_account.path_id),
           {:ok, _updated} <- mark_service_account_used(service_account.id) do
        # Emit telemetry
        :telemetry.execute(
          [:plugboard, :service_account, :validated],
          %{count: 1},
          %{path_id: service_account.path_id, user_id: service_account.user_id}
        )

        %{service_account: service_account, path: path, user_id: service_account.user_id}
      else
        {:error, reason} ->
          :telemetry.execute(
            [:plugboard, :service_account, :validation_failed],
            %{count: 1},
            %{reason: reason}
          )

          Repo.rollback(reason)
      end
    end)
  end

  def validate_and_mark_used(_), do: {:error, "Invalid API key format"}

  @doc """
  Revokes a service account, preventing it from generating new tokens.
  """
  def revoke_service_account(service_account_id) do
    case get_service_account(service_account_id) do
      nil ->
        {:error, :not_found}

      service_account ->
        result =
          service_account
          |> ServiceAccount.revoke_changeset()
          |> Repo.update()

        case result do
          {:ok, revoked_sa} ->
            :telemetry.execute(
              [:plugboard, :service_account, :revoked],
              %{count: 1},
              %{service_account_id: service_account_id, path_id: service_account.path_id}
            )

            {:ok, revoked_sa}

          error ->
            error
        end
    end
  end

  @doc """
  Lists all active service accounts for a given path.
  """
  def list_service_accounts_for_path(path_id) do
    ServiceAccount
    |> where([sa], sa.path_id == ^path_id)
    |> where([sa], is_nil(sa.revoked_at))
    |> order_by([sa], desc: sa.inserted_at)
    |> Repo.all()
  end

  @doc """
  Lists all service accounts for a given user.
  """
  def list_service_accounts_for_user(user_id) do
    ServiceAccount
    |> where([sa], sa.user_id == ^user_id)
    |> where([sa], is_nil(sa.revoked_at))
    |> order_by([sa], desc: sa.inserted_at)
    |> preload(:path)
    |> Repo.all()
  end

  @doc """
  Gets a single service account by ID.
  """
  def get_service_account(service_account_id) do
    Repo.get(ServiceAccount, service_account_id)
  end

  @doc """
  Updates a service account's name and description.

  ## Parameters
    - service_account_id: The ID of the service account to update
    - attrs: Map with :name and/or :description keys

  ## Returns
    - {:ok, updated_service_account} on success
    - {:error, changeset} on validation failure
    - {:error, :not_found} if service account doesn't exist
  """
  def update_service_account(service_account_id, attrs) do
    case get_service_account(service_account_id) do
      nil ->
        {:error, :not_found}

      service_account ->
        service_account
        |> ServiceAccount.update_changeset(attrs)
        |> Repo.update()
    end
  end

  ## Private functions

  defp create_service_account(attrs) do
    %ServiceAccount{}
    |> ServiceAccount.create_changeset(attrs)
    |> Repo.insert()
  end

  defp get_service_account_by_api_key_hash(api_key_hash) do
    case Repo.get_by(ServiceAccount, api_key_hash: api_key_hash) do
      nil -> {:error, :api_key_not_found}
      service_account -> {:ok, service_account}
    end
  end

  defp validate_service_account_active(service_account) do
    if service_account.revoked_at != nil do
      {:error, :service_account_revoked}
    else
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

  defp mark_service_account_used(service_account_id) do
    case get_service_account(service_account_id) do
      nil ->
        {:error, :not_found}

      service_account ->
        service_account
        |> ServiceAccount.mark_used_changeset()
        |> Repo.update()
    end
  end

  # API key generation and hashing

  defp generate_api_key do
    # Generate 32 bytes of random data and encode as base64
    # Format: sa_live_<base64>
    random_bytes = :crypto.strong_rand_bytes(32)
    encoded = Base.url_encode64(random_bytes, padding: false)
    "sa_live_#{encoded}"
  end

  defp hash_api_key(api_key) do
    :crypto.hash(:sha256, api_key)
    |> Base.encode16(case: :lower)
  end
end
