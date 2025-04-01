defmodule VeraWeb.BackendSocket do
  use Phoenix.Socket

  # Define your channels here, for example:
  channel "service/*", VeraWeb.ServiceBackend

  def connect(_params, socket, _connect_info) do
    {:ok, socket}
  end

  def id(_socket), do: nil
end
