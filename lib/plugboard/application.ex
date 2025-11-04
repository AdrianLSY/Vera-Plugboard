defmodule Plugboard.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Validate JWT secret before starting application (BLOCKER-3 fix)
    validate_jwt_secret!()

    children = [
      PlugboardWeb.Telemetry,
      Plugboard.Repo,
      {DNSCluster, query: Application.get_env(:plugboard, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Plugboard.PubSub},
      # Start the MountStore for in-memory mount point routing
      Plugboard.MountStore,
      # Start the MountNotifier to listen for PostgreSQL NOTIFY events
      Plugboard.MountNotifier,
      # Start the DistributedRegistry (Horde) for cluster-wide telephone tracking
      Plugboard.DistributedRegistry,
      # Start the ClusterConnector to sync libcluster events with Horde
      Plugboard.ClusterConnector,
      # TelephoneRegistry is now a compatibility shim - no process to start
      # It delegates all calls to DistributedRegistry
      # Start the TokenCleanup to periodically remove expired tokens
      Plugboard.TelephoneTokens.TokenCleanup,
      # Start a worker by calling: Plugboard.Worker.start_link(arg)
      # {Plugboard.Worker, arg},
      # Start to serve requests, typically the last entry
      PlugboardWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Plugboard.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    PlugboardWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  ## Private functions

  defp validate_jwt_secret! do
    secret = Application.get_env(:plugboard, PlugboardWeb.Endpoint)[:secret_key_base]

    cond do
      is_nil(secret) ->
        raise """
        SECRET_KEY_BASE is not configured. JWT authentication will fail.
        Generate a secret with: mix phx.gen.secret
        """

      byte_size(secret) < 64 ->
        raise """
        SECRET_KEY_BASE is too short (#{byte_size(secret)} bytes).
        Minimum 64 bytes required for secure JWT signing.
        Generate a new secret with: mix phx.gen.secret
        """

      Mix.env() == :prod and secret == get_dev_default_secret() ->
        raise """
        Using development SECRET_KEY_BASE in production!
        This is a critical security vulnerability.
        Set a production secret in your environment variables.
        """

      true ->
        :ok
    end
  end

  defp get_dev_default_secret do
    # This is the default secret from config/dev.exs
    # Used only to detect if dev secret is accidentally used in production
    "YcRGM5YHZp0vJHpDsNODO0+bjF8ulFk9fq8MqVuK7ZzYFYy2h8f3xLo3v+MFHYqy"
  end
end
