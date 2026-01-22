defmodule Plugboard.Hooks.Hook do
  @moduledoc """
  Schema for hooks - middleware that processes requests before reaching the target backend.

  Hooks can target:
  - Internal mount points (via telephone)
  - External HTTP endpoints

  They execute sequentially and merge their responses into the request body.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Plugboard.Paths.Path

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @target_types ~w(mount_point http_url)
  @default_allowed_status_codes [200, 201, 202, 204]

  # Blocked hosts for SSRF protection (can be disabled in test via config)
  # In test environment, set config :plugboard, :allow_localhost_hooks, true
  @blocked_hosts_production [
    "localhost",
    "127.0.0.1",
    "::1",
    "0.0.0.0",
    # AWS metadata
    "169.254.169.254",
    # GCP metadata
    "metadata.google.internal",
    # Alibaba metadata
    "100.100.100.200",
    # ECS task metadata
    "169.254.170.2"
  ]

  # Hosts blocked even in test mode (cloud metadata endpoints)
  @blocked_hosts_always [
    "169.254.169.254",
    "metadata.google.internal",
    "100.100.100.200",
    "169.254.170.2"
  ]

  # Sensitive headers that cannot be forwarded to hooks
  @blocked_headers [
    "cookie",
    "set-cookie",
    "authorization",
    "x-api-key",
    "x-auth-token",
    "proxy-authorization",
    "x-forwarded-for",
    "x-real-ip"
  ]

  schema "hooks" do
    field :name, :string
    field :description, :string

    # Target configuration
    field :target_type, :string, default: "mount_point"
    field :target_url, :string

    # Execution configuration
    field :execution_order, :integer, default: 0
    field :timeout_ms, :integer, default: 5000

    # Status code whitelisting
    field :allowed_status_codes, {:array, :integer}, default: @default_allowed_status_codes

    # Request configuration
    field :forward_headers, {:array, :string}, default: []
    field :forward_query_params, :boolean, default: false

    # Soft delete
    field :deleted_at, :utc_datetime

    # Associations
    belongs_to :path, Path
    belongs_to :target_path, Path

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating a new hook.
  """
  def create_changeset(hook, attrs) do
    hook
    |> cast(attrs, [
      :path_id,
      :name,
      :description,
      :target_type,
      :target_path_id,
      :target_url,
      :execution_order,
      :timeout_ms,
      :allowed_status_codes,
      :forward_headers,
      :forward_query_params
    ])
    |> validate_required([:path_id, :name, :target_type, :execution_order, :timeout_ms])
    |> validate_inclusion(:target_type, @target_types)
    |> validate_number(:timeout_ms, greater_than: 0, less_than_or_equal_to: 60_000)
    |> validate_number(:execution_order, greater_than_or_equal_to: 0)
    |> validate_target_config()
    |> validate_allowed_status_codes()
    |> validate_forward_headers()
    |> unique_constraint([:path_id, :execution_order],
      name: :hooks_unique_execution_order,
      message: "execution order already exists for this path"
    )
  end

  @doc """
  Changeset for updating a hook.
  """
  def update_changeset(hook, attrs) do
    hook
    |> cast(attrs, [
      :name,
      :description,
      :target_type,
      :target_path_id,
      :target_url,
      :execution_order,
      :timeout_ms,
      :allowed_status_codes,
      :forward_headers,
      :forward_query_params
    ])
    |> validate_required([:name, :target_type, :execution_order, :timeout_ms])
    |> validate_inclusion(:target_type, @target_types)
    |> validate_number(:timeout_ms, greater_than: 0, less_than_or_equal_to: 60_000)
    |> validate_number(:execution_order, greater_than_or_equal_to: 0)
    |> validate_target_config()
    |> validate_allowed_status_codes()
    |> validate_forward_headers()
    |> unique_constraint([:path_id, :execution_order],
      name: :hooks_unique_execution_order,
      message: "execution order already exists for this path"
    )
  end

  @doc """
  Changeset for soft-deleting a hook.
  """
  def delete_changeset(hook) do
    change(hook, deleted_at: DateTime.utc_now() |> DateTime.truncate(:second))
  end

  # Private validation functions

  defp validate_target_config(changeset) do
    target_type = get_field(changeset, :target_type)
    target_path_id = get_field(changeset, :target_path_id)
    target_url = get_field(changeset, :target_url)

    case target_type do
      "mount_point" ->
        changeset
        |> validate_required([:target_path_id])
        |> validate_target_path_id_not_nil(target_path_id)
        |> ensure_target_url_nil()

      "http_url" ->
        changeset
        |> validate_required([:target_url])
        |> validate_target_url_format(target_url)
        |> ensure_target_path_id_nil()

      _ ->
        changeset
    end
  end

  defp validate_target_path_id_not_nil(changeset, nil) do
    add_error(changeset, :target_path_id, "must be set when target_type is mount_point")
  end

  defp validate_target_path_id_not_nil(changeset, _target_path_id), do: changeset

  defp validate_target_url_format(changeset, nil) do
    add_error(changeset, :target_url, "must be set when target_type is http_url")
  end

  defp validate_target_url_format(changeset, target_url) when is_binary(target_url) do
    uri = URI.parse(target_url)

    cond do
      uri.scheme not in ["http", "https"] ->
        add_error(changeset, :target_url, "must use HTTP or HTTPS scheme")

      is_nil(uri.host) or uri.host == "" ->
        add_error(changeset, :target_url, "must have a valid host")

      blocked_host?(uri.host) ->
        add_error(changeset, :target_url, "cannot target internal or metadata hosts")

      internal_ip?(uri.host) ->
        add_error(changeset, :target_url, "cannot target private IP addresses")

      true ->
        changeset
    end
  end

  # Check if host is in the blocked list
  # In test mode with allow_localhost_hooks: true, only block cloud metadata endpoints
  defp blocked_host?(host) when is_binary(host) do
    host_lower = String.downcase(host)

    if Application.get_env(:plugboard, :allow_localhost_hooks, false) do
      # In test mode, only block cloud metadata endpoints
      host_lower in @blocked_hosts_always
    else
      # In production, block all internal hosts
      host_lower in @blocked_hosts_production
    end
  end

  defp blocked_host?(_), do: false

  # Check if host resolves to a private/internal IP address
  # In test mode with allow_localhost_hooks: true, allow private IPs
  defp internal_ip?(host) when is_binary(host) do
    if Application.get_env(:plugboard, :allow_localhost_hooks, false) do
      # In test mode, allow private IPs (for Bypass)
      false
    else
      case :inet.parse_address(String.to_charlist(host)) do
        {:ok, ip} -> private_ip?(ip)
        # Not an IP address, might be a hostname
        {:error, _} -> false
      end
    end
  end

  defp internal_ip?(_), do: false

  # Check if IP is in private ranges (RFC 1918, link-local, etc.)
  defp private_ip?({10, _, _, _}), do: true
  defp private_ip?({172, b, _, _}) when b >= 16 and b <= 31, do: true
  defp private_ip?({192, 168, _, _}), do: true
  defp private_ip?({127, _, _, _}), do: true
  # Link-local
  defp private_ip?({169, 254, _, _}), do: true
  defp private_ip?({0, 0, 0, 0}), do: true
  # IPv6 loopback and link-local
  defp private_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp private_ip?({0xFE80, _, _, _, _, _, _, _}), do: true
  defp private_ip?(_), do: false

  defp ensure_target_url_nil(changeset) do
    if get_field(changeset, :target_url) do
      add_error(changeset, :target_url, "must be nil when target_type is mount_point")
    else
      changeset
    end
  end

  defp ensure_target_path_id_nil(changeset) do
    if get_field(changeset, :target_path_id) do
      add_error(changeset, :target_path_id, "must be nil when target_type is http_url")
    else
      changeset
    end
  end

  defp validate_allowed_status_codes(changeset) do
    case get_field(changeset, :allowed_status_codes) do
      nil ->
        changeset

      [] ->
        add_error(changeset, :allowed_status_codes, "must contain at least one status code")

      codes when is_list(codes) ->
        if Enum.all?(codes, &is_integer/1) and Enum.all?(codes, &(&1 >= 100 and &1 < 600)) do
          changeset
        else
          add_error(
            changeset,
            :allowed_status_codes,
            "must be a list of valid HTTP status codes (100-599)"
          )
        end

      _ ->
        add_error(changeset, :allowed_status_codes, "must be a list of integers")
    end
  end

  defp validate_forward_headers(changeset) do
    case get_field(changeset, :forward_headers) do
      nil ->
        changeset

      [] ->
        changeset

      headers when is_list(headers) ->
        cond do
          not Enum.all?(headers, &is_binary/1) ->
            add_error(changeset, :forward_headers, "must be a list of strings")

          has_blocked_headers?(headers) ->
            blocked = get_blocked_headers(headers)

            add_error(
              changeset,
              :forward_headers,
              "cannot forward sensitive headers: #{Enum.join(blocked, ", ")}"
            )

          true ->
            changeset
        end

      _ ->
        add_error(changeset, :forward_headers, "must be a list of strings")
    end
  end

  defp has_blocked_headers?(headers) do
    Enum.any?(headers, fn h -> String.downcase(h) in @blocked_headers end)
  end

  defp get_blocked_headers(headers) do
    headers
    |> Enum.filter(fn h -> String.downcase(h) in @blocked_headers end)
    |> Enum.map(&String.downcase/1)
    |> Enum.uniq()
  end
end
