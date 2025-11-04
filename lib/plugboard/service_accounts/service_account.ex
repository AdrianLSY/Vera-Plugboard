defmodule Plugboard.ServiceAccounts.ServiceAccount do
  @moduledoc """
  Schema for service accounts used in Token Vending Machine.

  Service accounts allow programmatic generation of telephone tokens,
  enabling auto-scaling clusters to automatically obtain authentication
  credentials without manual intervention.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "service_accounts" do
    field :name, :string
    field :description, :string
    field :api_key_hash, :string
    field :revoked_at, :utc_datetime
    field :last_used_at, :utc_datetime

    belongs_to :user, Plugboard.Accounts.User
    belongs_to :path, Plugboard.Paths.Path

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating a new service account.
  """
  def create_changeset(service_account, attrs) do
    service_account
    |> cast(attrs, [:user_id, :path_id, :name, :description, :api_key_hash])
    |> validate_required([:user_id, :path_id, :name, :api_key_hash])
    |> validate_length(:name, min: 3, max: 100)
    |> validate_length(:description, max: 500)
    |> validate_format(:name, ~r/^[a-zA-Z0-9_-]+$/,
      message: "must contain only letters, numbers, hyphens, and underscores"
    )
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:path_id)
    |> unique_constraint([:user_id, :name],
      name: :service_accounts_unique_name_per_user,
      message: "name already exists for this user"
    )
    |> unique_constraint(:api_key_hash, name: :service_accounts_unique_api_key)
  end

  @doc """
  Changeset for revoking a service account.
  """
  def revoke_changeset(service_account) do
    service_account
    |> change()
    |> put_change(:revoked_at, DateTime.utc_now() |> DateTime.truncate(:second))
  end

  @doc """
  Changeset for updating last_used_at timestamp.
  """
  def mark_used_changeset(service_account) do
    service_account
    |> change()
    |> put_change(:last_used_at, DateTime.utc_now() |> DateTime.truncate(:second))
  end
end
