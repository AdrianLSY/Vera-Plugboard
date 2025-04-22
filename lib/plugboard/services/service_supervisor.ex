defmodule Plugboard.Services.ServiceSupervisor do
  use DynamicSupervisor

  def start_link(_arg) do
    DynamicSupervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start_service(service_id) do
    child_spec = {Plugboard.Services.ServiceConsumerRegistry, service_id: service_id}
    DynamicSupervisor.start_child(__MODULE__, child_spec)
  end

  def stop_service(service_id) do
    case GenServer.whereis(Plugboard.Services.ServiceConsumerRegistry.via_tuple(service_id)) do
      nil -> {:error, :not_found}
      pid -> DynamicSupervisor.terminate_child(__MODULE__, pid)
    end
  end
end
