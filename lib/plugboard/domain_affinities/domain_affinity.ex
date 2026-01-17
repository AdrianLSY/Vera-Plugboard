defmodule Plugboard.DomainAffinities.DomainAffinity do
  @moduledoc """
  Schema for domain affinities - mapping domains to mount points.

  A domain affinity allows a domain (e.g., `users.example.com`) to route
  directly to a mount point, bypassing the `/call` prefix.

  Supports:
  - Exact domains: `users.example.com`
  - Wildcard domains: `*.example.com`
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "domain_affinities" do
    field :domain, :string
    field :deleted_at, :utc_datetime

    belongs_to :path, Plugboard.Paths.Path

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(domain_affinity, attrs) do
    domain_affinity
    |> cast(attrs, [:domain, :path_id])
    |> validate_required([:domain, :path_id])
    |> normalize_domain()
    |> validate_domain_format()
    |> validate_path_is_mount_point()
    |> unique_constraint(:domain, name: :domain_affinities_unique_domain)
  end

  @doc """
  Returns true if the domain is a wildcard domain (starts with `*.`).
  """
  @spec wildcard?(%__MODULE__{}) :: boolean()
  def wildcard?(%__MODULE__{domain: domain}) do
    String.starts_with?(domain, "*.")
  end

  # Normalize domain: lowercase, strip whitespace, strip port
  defp normalize_domain(changeset) do
    case get_change(changeset, :domain) do
      nil ->
        changeset

      domain ->
        normalized =
          domain
          |> String.trim()
          |> String.downcase()
          |> String.replace(~r/:.*$/, "")

        put_change(changeset, :domain, normalized)
    end
  end

  # Validate domain format
  defp validate_domain_format(changeset) do
    validate_change(changeset, :domain, fn :domain, domain ->
      cond do
        # Wildcard domain (e.g., *.example.com)
        String.starts_with?(domain, "*.") ->
          # Must be *.example.com format with at least one dot in the base domain
          if Regex.match?(~r/^\*\.[a-z0-9][a-z0-9\-]*(\.[a-z0-9][a-z0-9\-]*)+$/, domain) do
            []
          else
            [domain: "invalid wildcard format"]
          end

        # Regular domain (e.g., example.com, subdomain.example.com)
        # Must contain at least one dot
        String.contains?(domain, ".") and
            Regex.match?(~r/^[a-z0-9][a-z0-9\-]*(\.[a-z0-9][a-z0-9\-]*)+$/, domain) ->
          []

        true ->
          [domain: "invalid domain format"]
      end
    end)
  end

  # Validate that the referenced path is a mount point
  defp validate_path_is_mount_point(changeset) do
    validate_change(changeset, :path_id, fn :path_id, path_id ->
      case Plugboard.Repo.get(Plugboard.Paths.Path, path_id) do
        nil -> [path_id: "path not found"]
        %{mount_point: false} -> [path_id: "path must be a mount point"]
        %{deleted_at: deleted_at} when not is_nil(deleted_at) -> [path_id: "path is deleted"]
        _ -> []
      end
    end)
  end
end
