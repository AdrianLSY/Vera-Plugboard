defmodule Plugboard.Services.ServiceManager do
  use GenServer
  alias Plugboard.Repo
  alias Plugboard.Services.Service
  alias Plugboard.Services.ServiceSupervisor

  def start_link(_) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    initialize_services()
    {:ok, %{}}
  end

  defp initialize_services do
    Service
    # TODO: Handle undeleting a service
    # Genservers are not automatically restarted when a service is undeleted.
    # For now, we will start all services regardless of their deleted_at value.
    # |> Service.default_scope()
    |> Repo.all()
    |> Enum.each(fn service ->
      ServiceSupervisor.start_service(service.id)
    end)
  end

  def handle_service_created(service) do
    ServiceSupervisor.start_service(service.id)
  end

  def handle_service_deleted(service) do
    ServiceSupervisor.stop_service(service.id)
  end
end
