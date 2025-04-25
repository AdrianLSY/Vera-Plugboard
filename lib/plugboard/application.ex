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
      {Finch, name: Plugboard.Finch},
      {Registry, keys: :unique, name: Plugboard.Services.ServiceRegistry},
      {Plugboard.Services.ServiceRequestRegistry, []},
      Plugboard.Services.ServiceSupervisor,
      Plugboard.Services.ServiceManager,
      PlugboardWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Plugboard.Services.Supervisor]
    Supervisor.start_link(children, opts)
  end

  def config_change(changed, _new, removed) do
    PlugboardWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
