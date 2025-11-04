defmodule Plugboard.TelephoneTokens.TelephoneToken do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "telephone_tokens" do
    field :token_hash, :string
    field :description, :string
    field :expires_at, :utc_datetime
    field :revoked_at, :utc_datetime
    field :last_used_at, :utc_datetime

    belongs_to :path, Plugboard.Paths.Path
    belongs_to :user, Plugboard.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating a new telephone token.
  """
  def create_changeset(token, attrs) do
    token
    |> cast(attrs, [:path_id, :user_id, :token_hash, :description, :expires_at])
    |> validate_required([:path_id, :user_id, :token_hash, :expires_at])
    |> foreign_key_constraint(:path_id)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:token_hash, name: :telephone_tokens_unique_hash)
  end

  @doc """
  Changeset for revoking a token.
  """
  def revoke_changeset(token) do
    token
    |> change()
    |> put_change(:revoked_at, DateTime.utc_now() |> DateTime.truncate(:second))
  end

  @doc """
  Changeset for updating last_used_at timestamp.
  """
  def mark_used_changeset(token) do
    token
    |> change()
    |> put_change(:last_used_at, DateTime.utc_now() |> DateTime.truncate(:second))
  end

  @doc """
  Changeset for refreshing token expiry.
  """
  def refresh_changeset(token, new_expires_at, new_token_hash) do
    token
    |> change()
    |> put_change(:expires_at, DateTime.truncate(new_expires_at, :second))
    |> put_change(:token_hash, new_token_hash)
  end
end
