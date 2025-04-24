defmodule PlugboardWeb.Services.ServiceConsumerSocket do
  use Phoenix.Socket
  alias Plugboard.Services.Services
  alias Plugboard.Services.ServiceActionRegistry
  alias Plugboard.Services.ServiceConsumerRegistry

  @service_token_validity_in_days System.get_env("PHX_SERVICE_TOKEN_VALIDITY_IN_DAYS") |> String.to_integer()

  channel "service", PlugboardWeb.Services.ServiceConsumerChannel

  def connect(%{"token" => token, "actions" => actions}, socket, _connect_info) do
    with {:ok, %{service: service, token: token_data}} <- Services.fetch_service_by_api_token(token) do
      service_id = to_string(service.id)

      if ServiceConsumerRegistry.num_consumers(service_id) > 0 do
        registered_actions = ServiceActionRegistry.actions(service_id)

        if Jason.decode!(actions) != registered_actions do
          {:error, %{reason: "Current consumer actions do not match other registered consumer actions"}}
        else
          complete_connection(socket, service, token_data, actions, service_id)
        end

      else
        complete_connection(socket, service, token_data, actions, service_id)
      end
    else
      _ -> {:error, %{reason: "Service API token is invalid"}}
    end
  end

  def connect(_params, _socket, _connect_info) do
    {:error, %{reason: "Authentication required"}}
  end

  def id(socket), do: "service:#{socket.assigns.service_id}"

  defp complete_connection(socket, service, token_data, actions, service_id) do
    token_response = %{
      id: token_data.id,
      context: token_data.context,
      service_id: service.id,
      inserted_at: token_data.inserted_at,
      expires_at: DateTime.add(token_data.inserted_at, @service_token_validity_in_days * 24 * 60 * 60, :second)
    }

    socket = socket
      |> assign(:service, service)
      |> assign(:token, token_response)
      |> assign(:actions, actions)
      |> assign(:service_id, service_id)

    {:ok, socket}
  end
end
