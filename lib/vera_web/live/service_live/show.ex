defmodule VeraWeb.ServiceLive.Show do
  use VeraWeb, :live_view

  alias Vera.Services

  @impl true
  def mount(params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Vera.PubSub, "service_#{params["id"]}")
    {:ok, stream(socket, :services, [])}
  end

  @impl true
  def handle_params(%{"id" => id}, _, socket) do
    service = Services.get_service!(id) |> Vera.Repo.preload([:parent, :children])
    children = service.children |> Vera.Repo.preload([:parent])

    {:noreply,
     socket
     |> stream(:services, children)
     |> assign(:page_title, page_title(socket.assigns.live_action))
     |> assign(:service, service)}
  end

  @impl true
  def handle_info({:service_updated, service}, socket) do
    service = Vera.Repo.preload(service, [:parent])
    if service.id == socket.assigns.service.id do
      {:noreply, assign(socket, :service, service)}
    else
      {:noreply, socket}
    end
  end


  def handle_info({:service_deleted, service}, socket) do
    service = Vera.Repo.preload(service, [:parent])
    if service.id == socket.assigns.service.id do
      {:noreply,
        socket
        |> put_flash(:error, "Service was deleted")
        |> push_navigate(to: ~p"/services")}
    else
      {:noreply, socket}
    end
  end

  defp page_title(:show), do: "Show Service"
  defp page_title(:edit), do: "Edit Service"
end
