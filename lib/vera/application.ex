defmodule Vera.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  def start(_type, _args) do
    children = [
      VeraWeb.Telemetry,
      Vera.Repo,
      {DNSCluster, query: Application.get_env(:vera, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Vera.PubSub},
      # Start the Finch HTTP client for sending emails
      {Finch, name: Vera.Finch},
      # Start the ServiceRegistry for mapping service IDs to client processes
      {Vera.Services.ServiceRegistry, []},
      # Start the GenStage producer for service messages
      {Vera.Services.ServiceRequestProducer, []},
      # Start the GenStage consumer for direct routing of messages
      {Vera.Services.ServiceRequestConsumer, []},
      # Start to serve requests, typically the last entry
      VeraWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Vera.Supervisor]
    Supervisor.start_link(children, opts)
  end

  def config_change(changed, _new, removed) do
    VeraWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
