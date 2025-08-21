defmodule PlugboardWeb.PageController do
  use PlugboardWeb, :controller

  alias Plugboard.Accounts.Accounts
  alias Plugboard.Services.Services
  alias PlugboardWeb.Accounts.AccountAuth
  alias PlugboardWeb.Services.ServiceAuth
  alias Plugboard.Services.ServiceRequestProducer
  alias Plugboard.Services.ServiceConsumerRegistry

  def home(conn, _params) do
    # The home page is often custom made,
    # so skip the default app layout.
    render(conn, :home, layout: false)
  end

  def request(conn, %{"service_id" => service_id, "action" => action, "fields" => fields}) do
    with {:ok, account} <- AccountAuth.fetch_api_account(conn, nil),
         true <- Accounts.is_authorized_for_service(account, service_id),
         {:ok, _msg} <- enqueue_service_request(service_id, action, fields) do
      handle_service_response(conn, service_id)
    else
      {:error, :unauthorized, reason} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{status: "error", message: reason})

      false ->
        conn
        |> put_status(:forbidden)
        |> json(%{status: "error", message: "Insufficient permissions for this service"})

      {:error, :unprocessable_entity, error_msg} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{status: "error", message: error_msg})
    end
  end

  def request(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{status: "error", message: "service_id, action and fields parameters are required"})
  end

  defp enqueue_service_request(service_id, action, fields) do
    ref = UUID.uuid4()

    request = %{
      action: action,
      fields: fields,
      response_ref: ref
    }

    case ServiceRequestProducer.enqueue(service_id, request) do
      {:ok, msg} ->
        ServiceConsumerRegistry.register_request(service_id, ref, self())
        {:ok, msg}

      {:error, error_msg} ->
        {:error, :unprocessable_entity, error_msg}
    end
  end

  defp handle_service_response(conn, _service_id) do
    receive do
      {:response, %{"status" => "success", "message" => message}} ->
        conn
        |> put_status(:ok)
        |> json(%{status: "success", message: message})

      {:response, %{"status" => _status, "message" => message}} ->
        conn
        |> put_status(:bad_request)
        |> json(%{status: "error", message: message})

      {:response, _invalid_response} ->
        conn
        |> put_status(:bad_gateway)
        |> json(%{
          status: "error",
          message: "Invalid response format from service process"
        })
    after
      30_000 ->
        conn
        |> put_status(:request_timeout)
        |> json(%{status: "error", message: "Request timed out"})
    end
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
