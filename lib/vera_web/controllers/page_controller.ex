defmodule VeraWeb.PageController do
  use VeraWeb, :controller

  def home(conn, _params) do
    # The home page is often custom made,
    # so skip the default app layout.
    render(conn, :home, layout: false)
  end

  def request(conn, %{"service_id" => service_id, "payload" => payload}) do
    payload = %{
      service_id: service_id,
      payload: payload
    }

    case Vera.Services.ServiceRequestProducer.enqueue(payload) do
      {:ok, _msg} ->
        conn
        |> put_status(:ok)
        |> json(%{status: "success", message: "Content sent to client"})

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
