defmodule PlugboardWeb.PageController do
  use PlugboardWeb, :controller

  alias Plugboard.Accounts.Accounts
  alias Plugboard.Services.Services
  alias PlugboardWeb.Accounts.AccountAuth
  alias PlugboardWeb.Services.ServiceAuth

  def home(conn, _params) do
    # The home page is often custom made,
    # so skip the default app layout.
    render(conn, :home, layout: false)
  end

  def request(conn, %{"service_id" => service_id, "action" => action, "fields" => fields}) do
    case AccountAuth.fetch_api_account(conn, nil) do
      {:ok, _account} ->
        ref = UUID.uuid4()
        request = %{
          action: action,
          fields: fields,
          response_ref: ref
        }
        case Plugboard.Services.ServiceRequestProducer.enqueue(service_id, request) do
          {:ok, _msg} ->
            Plugboard.Services.ServiceRequestRegistry.register_request(ref, self())
            receive do
              {:response, response_payload} ->
                case response_payload do
                  %{"status" => status, "message" => message} ->
                    if status == "success" do
                      conn
                      |> put_status(:ok)
                      |> json(%{status: "success", message: message})
                    else
                      conn
                      |> put_status(:bad_request)
                      |> json(%{status: "error", message: message})
                    end
                  _ ->
                    conn
                    |> put_status(:bad_gateway)
                    |> json(%{status: "error", message: "Invalid response format from service process"})
                end
            after
              30_000 ->
                conn
                |> put_status(:request_timeout)
                |> json(%{status: "error", message: "Request timed out"})
            end

              {:error, error_msg} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{status: "error", message: error_msg})
        end
      {:error, reason} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{status: "error", message: reason})
      end
  end

  def request(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{status: "error", message: "service_id and payload parameters are required"})
  end

  def account_token(conn, _params) do
    case AccountAuth.fetch_api_account(conn, nil) do
      {:ok, account} ->
        token = Accounts.create_account_api_token(account)
        conn
        |> put_status(:ok)
        |> json(%{status: "success", message: "Account API token created", token: token})

      {:error, reason} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{status: "error", message: reason})
    end
  end

  def service_token(conn, _params) do
    case ServiceAuth.fetch_api_service(conn, nil) do
      {:ok, service} ->
        token = Services.create_service_api_token(service)
        conn
        |> put_status(:ok)
        |> json(%{status: "success", message: "Service API token created", token: token})

      {:error, reason} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{status: "error", message: reason})
    end
  end
end
