defmodule PlugboardWeb.Services.ServiceConsumerSocket do
  use Phoenix.Socket

  ## Channels
  channel "service/*", PlugboardWeb.Services.ServiceConsumerChannel

  def connect(_params, socket, _connect_info) do
    {:ok, socket}
  end

  def id(_socket), do: nil
end
