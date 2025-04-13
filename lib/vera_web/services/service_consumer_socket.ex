defmodule VeraWeb.Services.ServiceConsumerSocket do
  use Phoenix.Socket

  ## Channels
  channel "service/*", VeraWeb.Services.ServiceConsumerChannel

  def connect(_params, socket, _connect_info) do
    {:ok, socket}
  end

  def id(_socket), do: nil
end
