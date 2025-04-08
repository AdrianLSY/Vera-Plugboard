defmodule VeraWeb.PageController do
  use VeraWeb, :controller

  def home(conn, _params) do
    # The home page is often custom made,
    # so skip the default app layout.
    render(conn, :home, layout: false)
  end

  def request(conn, %{"service_id" => service_id, "message" => message}) do
    message = %{
      service_id: service_id,
      message: message
    }

    case Vera.Queue.ServiceRequestProducer.enqueue(message) do
      {:ok, _msg} ->
        conn
        |> put_status(:ok)
        |> json(%{status: "success", message: "Message sent to client"})

      {:error, error_msg} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{status: "error", message: error_msg})
    end
  end

  def request(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{status: "error", message: "service_id and message parameters are required"})
  end
end
