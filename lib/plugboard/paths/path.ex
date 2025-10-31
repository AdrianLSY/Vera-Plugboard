defmodule Plugboard.Paths.Path do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "paths" do
    field :path, :string
    field :full_path, :string
    field :mount_point, :boolean, default: false
    field :deleted_at, :utc_datetime

    belongs_to :user, Plugboard.Accounts.User
    belongs_to :created_by_user, Plugboard.Accounts.User
    belongs_to :parent, __MODULE__

    has_many :children, __MODULE__, foreign_key: :parent_id

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating a new path.

  Note: full_path is computed by database trigger and should not be set manually.
  """
  def create_changeset(path, attrs) do
    path
    |> cast(attrs, [:path, :parent_id, :user_id, :created_by_user_id, :mount_point])
    |> validate_required([:path, :user_id, :created_by_user_id])
    |> validate_path_segment()
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:created_by_user_id)
    |> foreign_key_constraint(:parent_id)
    |> unique_constraint(:path, name: :paths_unique_sibling_path)
  end

  @doc """
  Changeset for updating an existing path.
  """
  def update_changeset(path, attrs) do
    path
    |> cast(attrs, [:path, :mount_point])
    |> validate_path_segment()
  end

  @doc """
  Changeset for restoring a soft-deleted path.
  """
  def restore_changeset(path, attrs) do
    path
    |> cast(attrs, [:deleted_at, :mount_point])
    |> put_change(:deleted_at, nil)
    |> put_change(:mount_point, false)
    |> put_change(:updated_at, DateTime.utc_now() |> DateTime.truncate(:second))
  end

  @doc """
  Changeset for soft-deleting a path.
  """
  def delete_changeset(path) do
    path
    |> change()
    |> put_change(:deleted_at, DateTime.utc_now() |> DateTime.truncate(:second))
  end

  # Private validation functions

  defp validate_path_segment(changeset) do
    changeset
    |> validate_format(:path, ~r/^[a-zA-Z0-9_\-\.]+$/,
      message: "must contain only alphanumeric characters, hyphens, underscores, and dots"
    )
    |> validate_format(:path, ~r/^[^\/]+$/, message: "must not contain forward slashes")
    |> validate_length(:path, min: 1, max: 255)
  end
end
