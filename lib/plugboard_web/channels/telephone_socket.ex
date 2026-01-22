defmodule PlugboardWeb.TelephoneSocket do
  @moduledoc """
  Socket for telephone WebSocket connections.

  Authenticates telephones using JWT tokens and establishes persistent
  WebSocket connections for proxying HTTP traffic.
  """

  use Phoenix.Socket

  require Logger

  alias Plugboard.TelephoneTokens

  ## Channels
  channel "telephone:*", PlugboardWeb.TelephoneChannel

  @impl true
  def connect(%{"token" => jwt_token}, socket, _connect_info) do
    # Use validate_and_mark_used to prevent race condition (BLOCKER-1 fix)
    case TelephoneTokens.validate_and_mark_used(jwt_token) do
      {:ok, %{token: token, path: path, user_id: user_id}} ->
        socket =
          socket
          |> assign(:token_id, token.id)
          |> assign(:path_id, path.id)
          |> assign(:path, path)
          |> assign(:user_id, user_id)

        Logger.info("Telephone authenticated for path #{path.full_path}")

        {:ok, socket}

      {:error, reason} ->
        Logger.warning("Telephone authentication failed: #{inspect(reason)}")
        :error
    end
  end

  def connect(_params, _socket, _connect_info) do
    Logger.warning("Telephone connection attempt missing token")
    :error
  end

  @impl true
  def id(socket) do
    "telephone:#{socket.assigns.path_id}:#{socket.assigns.token_id}"
  end
end
