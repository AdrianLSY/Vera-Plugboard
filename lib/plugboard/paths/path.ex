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

    field :request_timeout_ms, :integer, default: 60000
    field :connect_timeout_ms, :integer, default: 5000

    belongs_to :parent, __MODULE__

    has_many :children, __MODULE__, foreign_key: :parent_id
    has_many :user_paths, Plugboard.Paths.UserPath
    has_many :telephone_tokens, Plugboard.TelephoneTokens.TelephoneToken
    many_to_many :users, Plugboard.Accounts.User, join_through: Plugboard.Paths.UserPath

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating a new path.

  Note: full_path is computed by database trigger and should not be set manually.
  User associations are managed separately through the user_paths junction table.
  """
  def create_changeset(path, attrs) do
    path
    |> cast(attrs, [:path, :parent_id, :mount_point])
    |> validate_required([:path])
    |> validate_path_segment()
    |> foreign_key_constraint(:parent_id)
    |> unique_constraint(:path, name: :paths_unique_sibling_path)
  end

  @doc """
  Changeset for updating an existing path.
  """
  def update_changeset(path, attrs) do
    path
    |> cast(attrs, [:path, :mount_point, :request_timeout_ms, :connect_timeout_ms])
    |> validate_path_segment()
    |> validate_number(:request_timeout_ms, greater_than: 0, less_than_or_equal_to: 300_000)
    |> validate_number(:connect_timeout_ms, greater_than: 0, less_than_or_equal_to: 60_000)
  end

  @doc """
  Changeset for restoring a soft-deleted path.

  This function is idempotent - calling it multiple times on an already
  restored path will return a no-op changeset.
  """
  def restore_changeset(path, attrs) do
    # If already restored, return no-op changeset (idempotent)
    if is_nil(path.deleted_at) do
      Ecto.Changeset.change(path, %{})
    else
      path
      |> cast(attrs, [:deleted_at, :mount_point])
      |> put_change(:deleted_at, nil)
      |> put_change(:mount_point, false)
      |> put_change(:updated_at, DateTime.utc_now() |> DateTime.truncate(:second))
    end
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
