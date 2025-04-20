defmodule VeraWeb.ServiceLive.Show do
  use VeraWeb, :live_view

  alias Vera.Services.Service
  alias Vera.Services.Services
  alias Vera.Services.ServiceToken

  def mount(params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Vera.PubSub, "service/#{params["id"]}")
    end
    {:ok, stream(socket, :services, [])}
  end

  def handle_params(%{"id" => id} = params, _, socket) do
    service = Services.get_service!(id) |> Vera.Repo.preload([:parent, :children])
    childrens = service.children |> Vera.Repo.preload([:parent])
    full_path = Service.full_path(service)
    consumers_connected = Vera.Services.ServiceConsumerRegistry.list_consumers(service.id) |> length()
    actions = Vera.Services.ServiceActionRegistry.get_actions(service.id)
    tokens = list_service_tokens(service)
    socket = socket
      |> assign(:service, service)
      |> stream(:services, childrens)
      |> stream(:tokens, tokens)
      |> assign(:full_path, full_path)
      |> assign(:consumers_connected, consumers_connected)
      |> assign(:actions, actions)
      |> assign(:page_title, page_title(socket.assigns.live_action))
      |> assign(:new_token, nil)
      |> assign_form_service(socket.assigns.live_action, params)

    {:noreply, socket}
  end

  defp list_service_tokens(service) do
    ServiceToken.by_service_and_contexts_query(service, ["api-token"])
    |> Vera.Repo.all()
  end

  defp assign_form_service(socket, :new, _params) do
    assign(socket, :form_service, %Service{parent_id: socket.assigns.service.id})
  end

  defp assign_form_service(socket, :edit, %{"child_id" => child_id}) do
    service = Services.get_service!(child_id)
    assign(socket, :form_service, service)
  end

  defp assign_form_service(socket, :edit, %{"id" => id}) do
    service = Services.get_service!(id)
    assign(socket, :form_service, service)
  end

  defp assign_form_service(socket, _action, _params), do: socket

  def handle_info({VeraWeb.ServiceLive.FormComponent, {:saved, service}}, socket) do
    service = Vera.Repo.preload(service, [:parent])
    {:noreply, stream_insert(socket, :services, service)}
  end

  def handle_info({:service_created, service}, socket) do
    service = Vera.Repo.preload(service, [:parent])
    if service.parent_id == socket.assigns.service.id do
      {:noreply,
        socket
        |> put_flash(:info, "Child service created")
        |> stream_insert(:services, service)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:service_updated, service}, socket) do
    service = Vera.Repo.preload(service, [:parent])
    cond do
      service.id == socket.assigns.service.id ->
        {:noreply,
          socket
          |> assign(:service, service)}
      service.parent_id == socket.assigns.service.id ->
        {:noreply,
          socket
          |> put_flash(:info, "Child service updated")
          |> stream_insert(:services, service)}
      true ->
        {:noreply, socket}
    end
  end

  def handle_info({:service_deleted, service, redirect_service_id}, socket) do
    service = Vera.Repo.preload(service, [:parent])
    cond do
      service.id == socket.assigns.service.id ->
        {:noreply,
          socket
          |> put_flash(:info, "Service deleted, redirected to closest ancestor")
          |> push_navigate(to: (if redirect_service_id, do: ~p"/services/#{redirect_service_id}", else: ~p"/services"))}
      service.parent_id == socket.assigns.service.id ->
        {:noreply,
          socket
          |> put_flash(:info, "Child service deleted")
          |> stream_delete(:services, service)}
      true ->
        {:noreply, socket}
    end
  end

  def handle_info({:path_updated, full_path}, socket) do
    {:noreply,
      socket
      |> put_flash(:info, "Service path updated")
      |> assign(:full_path, full_path)}
  end

  def handle_info({:consumers_connected, consumers_connected}, socket) do
    {:noreply, assign(socket, :consumers_connected, consumers_connected)}
  end

  def handle_info({:actions, actions}, socket) do
    {:noreply, assign(socket, :actions, actions)}
  end

  def handle_info({:token_created, token}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, "API token created")
     |> stream_insert(:tokens, token)
     |> assign(:new_token, token.value)}
  end

  def handle_info({:token_deleted, token}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, "API token deleted")
     |> stream_delete(:tokens, token)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    service = Services.get_service!(id)
    {:ok, _} = Services.delete_service(service)
    {:noreply, socket}
  end

  def handle_event("create_token", _params, socket) do
    service = socket.assigns.service
    Services.create_service_api_token(service)
    {:noreply, socket}
  end

  def handle_event("delete_token", %{"id" => token_id}, socket) do
    {id, _} = Integer.parse(token_id)
    token = Vera.Repo.get!(Vera.Services.ServiceToken, id)
    {:ok, _} = Vera.Repo.delete(token)
    Phoenix.PubSub.broadcast(Vera.PubSub, "service/#{socket.assigns.service.id}", {:token_deleted, token})
    {:noreply, socket}
  end

  def handle_event("dismiss_token", _params, socket) do
    {:noreply, assign(socket, :new_token, nil)}
  end

  defp page_title(:new), do: "New Service"
  defp page_title(:show), do: "Plugboard Service"
  defp page_title(:edit), do: "Edit Service"
  defp page_title(:delete), do: "Delete Service"
end
