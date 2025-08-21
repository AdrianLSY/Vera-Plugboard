defmodule Plugboard.Services.ServiceSupervisor do
  use DynamicSupervisor
  alias Plugboard.Services.ServiceRequestProducer
  alias Plugboard.Services.ServiceRequestConsumer
  alias Plugboard.Services.ServiceConsumerRegistry

  def start_link(_arg) do
    DynamicSupervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start_service(service_id) do
    children = [
      {ServiceRequestProducer, service_id: service_id},
      {ServiceRequestConsumer, service_id: service_id},
      {ServiceConsumerRegistry, service_id: service_id}
    ]

    DynamicSupervisor.start_child(__MODULE__, %{
      id: {:service_supervisor, service_id},
      start: {Supervisor, :start_link, [children, [strategy: :one_for_all]]},
      type: :supervisor
    })
  end

  def stop_service(service_id) do
    case DynamicSupervisor.which_children(__MODULE__)
         |> Enum.find(fn {id, _, _, _} -> id == {:service_supervisor, service_id} end) do
      nil ->
        {:error, :not_found}

      {_, pid, _, _} ->
        DynamicSupervisor.terminate_child(__MODULE__, pid)
    end
  end
end
