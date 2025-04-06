defmodule VeraWeb.ServiceRequestController do
  use VeraWeb, :controller

  def request(conn, %{"id" => service_id} = params) do
    message = %{
      service_id: service_id,
      message: params["message"]
    }
    Vera.Queue.ServiceRequestProducer.enqueue(message)

    conn
    |> put_status(:accepted)
    |> json(%{status: "accepted"})
  end
end
