defmodule VeraWeb.ServiceLive.FormComponent do
  use VeraWeb, :live_component

  alias Vera.Services

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.header>
        {@title}
        <:subtitle>Use this form to manage service records in your database.</:subtitle>
      </.header>

      <.simple_form
        for={@form}
        id="service-form"
        phx-target={@myself}
        phx-change="validate"
        phx-submit="save"
      >
        <.input field={@form[:name]} type="text" label="Name" />
        <:actions>
          <.button phx-disable-with="Saving...">Save Service</.button>
        </:actions>
      </.simple_form>
    </div>
    """
  end

  @impl true
  def update(%{service: service} = assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:form, fn ->
       to_form(Services.change_service(service))
     end)}
  end

  @impl true
  def handle_event("validate", %{"service" => service_params}, socket) do
    changeset = Services.change_service(socket.assigns.service, service_params)
    {:noreply, assign(socket, form: to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"service" => service_params}, socket) do
    save_service(socket, socket.assigns.action, service_params)
  end

  defp save_service(socket, :edit, service_params) do
    case Services.update_service(socket.assigns.service, service_params) do
      {:ok, service} ->
        notify_parent({:saved, service})

        {:noreply,
         socket
         |> put_flash(:info, "Service updated successfully")
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp save_service(socket, :new, service_params) do
    case Services.create_service(service_params) do
      {:ok, service} ->
        notify_parent({:saved, service})

        {:noreply,
         socket
         |> put_flash(:info, "Service created successfully")
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp notify_parent(msg), do: send(self(), {__MODULE__, msg})
end
