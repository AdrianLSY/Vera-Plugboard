defmodule VeraWeb.BackendSocket do
  use Phoenix.Socket

  ## Channels
  channel "backend/service/*", VeraWeb.BackendChannel

  def connect(_params, socket, _connect_info) do
    {:ok, socket}
  end

  def id(_socket), do: nil
end
