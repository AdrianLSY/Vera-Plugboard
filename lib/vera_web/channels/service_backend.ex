defmodule VeraWeb.ServiceBackend do
  use Phoenix.Channel

  def join("backend/service/" <> service_id, _params, socket) do
    :ok = Phoenix.PubSub.subscribe(Vera.PubSub, "service/#{service_id}")
    {:ok, assign(socket, :service_id, service_id)}
  end

  def handle_info({event, payload} = _payload, socket) when is_atom(event) do
    push(socket, Atom.to_string(event), payload)
    {:noreply, socket}
  end
end
