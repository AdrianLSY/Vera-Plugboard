defmodule VeraWeb.ServiceLive.Index do
  use VeraWeb, :live_view

  alias Vera.Services
  alias Vera.Services.Service

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Vera.PubSub, "services")
    services = Services.list_services()
      |> Vera.Repo.preload([:parent])
      |> Enum.filter(fn service -> is_nil(service.parent_id) end)
    {:ok, stream(socket, :services, services)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    socket
    |> assign(:page_title, "Edit Service")
    |> assign(:service, Services.get_service!(id))
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New Service")
    |> assign(:service, %Service{})
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Plugboard Services")
    |> assign(:service, nil)
  end

  @impl true
  def handle_info({VeraWeb.ServiceLive.FormComponent, {:saved, service}}, socket) do
    service = Vera.Repo.preload(service, [:parent])
    {:noreply, stream_insert(socket, :services, service)}
  end

  @impl true
  def handle_info({:service_created, service}, socket) do
    service = Vera.Repo.preload(service, [:parent])
    {:noreply,
      socket
      |> put_flash(:info, "Service created")
      |> stream_insert(:services, service)}
  end

  @impl true
  def handle_info({:service_updated, service}, socket) do
    service = Vera.Repo.preload(service, [:parent])
    {:noreply,
      socket
      |> put_flash(:info, "Service updated")
      |> stream_insert(:services, service)}
  end

  @impl true
  def handle_info({:service_deleted, service}, socket) do
    {:noreply,
      socket
      |> put_flash(:info, "Service deleted")
      |> stream_delete(:services, service)}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    service = Services.get_service!(id)
    {:ok, _} = Services.delete_service(service)

    {:noreply, stream_delete(socket, :services, service)}
  end
end
