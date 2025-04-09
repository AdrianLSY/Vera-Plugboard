defmodule VeraWeb.PageController do
  use VeraWeb, :controller

  def home(conn, _params) do
    # The home page is often custom made,
    # so skip the default app layout.
    render(conn, :home, layout: false)
  end

  def request(conn, %{"service_id" => service_id, "payload" => payload}) do
    ref = UUID.uuid4()
    # Restructure the payload to be flat
    request = %{
      service_id: service_id,
      payload: payload,
      response_ref: ref
    }

    case Vera.Services.ServiceRequestProducer.enqueue(request) do
      {:ok, _msg} ->
        Vera.Services.ServiceRequestRegistry.register_request(ref, self())
        receive do
          {:response, response_payload} ->
            conn
            |> put_status(:ok)
            |> json(%{status: "success", response: response_payload})
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
  end

  def request(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{status: "error", message: "service_id and payload parameters are required"})
  end
end
