defmodule PlugboardWeb.Services.ServiceAuth do
  use PlugboardWeb, :verified_routes

  import Plug.Conn

  alias Plugboard.Services.Services

  @doc """
  Fetches the account from the api token.
  """
  def fetch_api_service(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, %{service: service, token: token}} <- Services.fetch_service_by_api_token(token) do
      {:ok, %{service: service, token: token}}
    else
      _ -> {:error, "API token is invalid"}
    end
  end
end
