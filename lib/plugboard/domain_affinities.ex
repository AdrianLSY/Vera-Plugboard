defmodule Plugboard.DomainAffinities do
  @moduledoc """
  Context for managing domain affinities (domain → mount point mappings).

  Domain affinities allow domains to route directly to mount points:
  - `users.example.com` → `/call/users`
  - `*.api.example.com` → `/call/api`

  This enables vanity URLs and bypasses the `/call` prefix for specific domains.
  """

  import Ecto.Query
  alias Plugboard.Repo
  alias Plugboard.DomainAffinities.DomainAffinity

  @doc """
  Lists all active domain affinities.

  ## Examples

      iex> list_domain_affinities()
      [%DomainAffinity{}, ...]
  """
  def list_domain_affinities do
    DomainAffinity
    |> where([da], is_nil(da.deleted_at))
    |> order_by([da], asc: da.domain)
    |> preload(:path)
    |> Repo.all()
  end

  @doc """
  Lists domain affinities for a specific path.

  ## Examples

      iex> list_domain_affinities_for_path(path_id)
      [%DomainAffinity{}, ...]
  """
  def list_domain_affinities_for_path(path_id) do
    DomainAffinity
    |> where([da], da.path_id == ^path_id and is_nil(da.deleted_at))
    |> order_by([da], asc: da.domain)
    |> Repo.all()
  end

  @doc """
  Gets a single domain affinity by ID.

  Returns `nil` if the domain affinity does not exist or is deleted.

  ## Examples

      iex> get_domain_affinity(id)
      %DomainAffinity{}

      iex> get_domain_affinity("nonexistent")
      nil
  """
  def get_domain_affinity(id) do
    DomainAffinity
    |> where([da], da.id == ^id and is_nil(da.deleted_at))
    |> preload(:path)
    |> Repo.one()
  end

  @doc """
  Gets a domain affinity by domain string.

  The domain is normalized before lookup (lowercased, port stripped).

  ## Examples

      iex> get_by_domain("users.example.com")
      %DomainAffinity{}

      iex> get_by_domain("unknown.com")
      nil
  """
  def get_by_domain(domain) do
    normalized = normalize_domain(domain)

    DomainAffinity
    |> where([da], da.domain == ^normalized and is_nil(da.deleted_at))
    |> preload(:path)
    |> Repo.one()
  end

  @doc """
  Creates a domain affinity.

  ## Examples

      iex> create_domain_affinity(%{domain: "users.example.com", path_id: path_id})
      {:ok, %DomainAffinity{}}

      iex> create_domain_affinity(%{domain: "invalid"})
      {:error, %Ecto.Changeset{}}
  """
  def create_domain_affinity(attrs) do
    %DomainAffinity{}
    |> DomainAffinity.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a domain affinity.

  ## Examples

      iex> update_domain_affinity(id, %{domain: "new.example.com"})
      {:ok, %DomainAffinity{}}

      iex> update_domain_affinity("nonexistent", %{})
      {:error, :not_found}
  """
  def update_domain_affinity(id, attrs) do
    case get_domain_affinity(id) do
      nil ->
        {:error, :not_found}

      domain_affinity ->
        domain_affinity
        |> DomainAffinity.changeset(attrs)
        |> Repo.update()
    end
  end

  @doc """
  Soft-deletes a domain affinity.

  ## Examples

      iex> delete_domain_affinity(id)
      {:ok, %DomainAffinity{}}

      iex> delete_domain_affinity("nonexistent")
      {:error, :not_found}
  """
  def delete_domain_affinity(id) do
    case get_domain_affinity(id) do
      nil ->
        {:error, :not_found}

      domain_affinity ->
        domain_affinity
        |> Ecto.Changeset.change(deleted_at: DateTime.utc_now() |> DateTime.truncate(:second))
        |> Repo.update()
    end
  end

  @doc """
  Normalizes a domain string for consistent comparison.

  - Trims whitespace
  - Converts to lowercase
  - Strips port number (e.g., `:8080`)

  ## Examples

      iex> normalize_domain("Users.Example.COM:8080")
      "users.example.com"

      iex> normalize_domain("  api.example.com  ")
      "api.example.com"
  """
  def normalize_domain(domain) do
    domain
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/:.*$/, "")
  end
end
