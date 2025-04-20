defmodule Plugboard.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  def start(_type, _args) do
    children = [
      PlugboardWeb.Telemetry,
      Plugboard.Repo,
      {DNSCluster, query: Application.get_env(:plugboard, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Plugboard.PubSub},
      # Start the Finch HTTP client for sending emails
      {Finch, name: Plugboard.Finch},
      # Start the ServiceConsumerRegistry for mapping service IDs to client processes
      {Plugboard.Services.ServiceConsumerRegistry, []},
      # Start the ServiceActionRegistry for mapping service IDs to actions
      {Plugboard.Services.ServiceActionRegistry, []},
      # Start the RequestRegistry for mapping response_ref to client processes
      {Plugboard.Services.ServiceRequestRegistry, []},
      # Start the GenStage producer for service messages
      {Plugboard.Services.ServiceRequestProducer, []},
      # Start the GenStage consumer for direct routing of messages
      {Plugboard.Services.ServiceRequestConsumer, []},
      # Start to serve requests, typically the last entry
      PlugboardWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Plugboard.Supervisor]
    Supervisor.start_link(children, opts)
  end

  def config_change(changed, _new, removed) do
    PlugboardWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
