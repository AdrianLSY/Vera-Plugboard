defmodule Plugboard.Paths.UserPath do
  @moduledoc """
  Schema for user-path associations with role-based access control.

  Links users to paths with one of three roles:
  - `owner` - Full control, can manage path and grant access
  - `maintainer` - Can manage tokens and service accounts
  - `viewer` - Read-only access to path information
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @valid_roles ~w(owner maintainer viewer)

  schema "user_paths" do
    field :role, :string

    belongs_to :user, Plugboard.Accounts.User
    belongs_to :path, Plugboard.Paths.Path

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or updating a user_path association.
  """
  def changeset(user_path, attrs) do
    user_path
    |> cast(attrs, [:user_id, :path_id, :role])
    |> validate_required([:user_id, :path_id, :role])
    |> validate_inclusion(:role, @valid_roles)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:path_id)
    |> unique_constraint([:user_id, :path_id], name: :user_paths_unique_user_path)
  end

  @doc """
  Returns the list of valid roles.
  """
  def valid_roles, do: @valid_roles
end
