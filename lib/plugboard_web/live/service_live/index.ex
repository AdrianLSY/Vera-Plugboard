defmodule PlugboardWeb.ServiceLive.Index do
  use PlugboardWeb, :live_view
  alias Phoenix.PubSub
  alias Plugboard.Services.Service
  alias Plugboard.Services.Services

  def mount(_params, _session, socket) do
    if connected?(socket), do: PubSub.subscribe(Plugboard.PubSub, "services")
    services = Services.list_root_services()
    {:ok, stream(socket, :services, services)}
  end

  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    socket
    |> assign(:page_title, "Plugboard | Edit Service")
    |> assign(:service, Services.get_service!(id))
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "Plugboard | New Service")
    |> assign(:service, %Service{})
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Plugboard | Services")
    |> assign(:service, nil)
  end

  def handle_info({PlugboardWeb.ServiceLive.FormComponent, {:saved, service}}, socket) do
    service = Plugboard.Repo.preload(service, [:parent])
    {:noreply, stream_insert(socket, :services, service)}
  end

  def handle_info({:service_created, service}, socket) do
    service = Plugboard.Repo.preload(service, [:parent])
    {:noreply,
      socket
      |> put_flash(:info, "Service created")
      |> stream_insert(:services, service)}
  end

  def handle_info({:service_updated, service}, socket) do
    service = Plugboard.Repo.preload(service, [:parent])
    {:noreply,
      socket
      |> put_flash(:info, "Service updated")
      |> stream_insert(:services, service)}
  end

  def handle_info({:service_deleted, service}, socket) do
    {:noreply,
      socket
      |> put_flash(:info, "Service deleted")
      |> stream_delete(:services, service)}
  end


  def handle_event("delete", %{"id" => id}, socket) do
    service = Services.get_service!(id)
    {:ok, _} = Services.delete_service(service)

    {:noreply, stream_delete(socket, :services, service)}
  end
end
