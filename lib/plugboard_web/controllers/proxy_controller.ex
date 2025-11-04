defmodule PlugboardWeb.ProxyController do
  @moduledoc """
  Controller for handling proxy requests to backend telephones.

  This controller receives requests at `/proxies/*path` and routes them to
  the appropriate backend telephone based on the mount point matching.

  Phase 3 implements actual WebSocket-based proxying to telephones.
  """

  use PlugboardWeb, :controller
  require Logger

  alias Plugboard.TelephoneRegistry
  alias Plugboard.Paths

  @doc """
  Handles all proxy requests.

  Routing logic:
  1. Extract the request path after `/proxies/`
  2. Use MountStore.match/1 to find a matching mount point
  3. If match found, proxy request to telephone via WebSocket
  4. If no match or no telephone available, return appropriate error
  """
  def proxy(conn, params) do
    # Extract the full path from params - Phoenix captures it as a list
    request_path = build_request_path(params)

    Logger.debug("ProxyController: Handling request for path: #{request_path}")

    case Plugboard.MountStore.match(request_path) do
      {:ok, {mount_path, forwarded_path, mount_id}} ->
        Logger.info(
          "ProxyController: Matched mount #{mount_path} (#{mount_id}), forwarding: #{forwarded_path}"
        )

        proxy_to_telephone(conn, mount_id, forwarded_path)

      {:error, :not_found} ->
        Logger.debug("ProxyController: No mount found for path: #{request_path}")

        conn
        |> put_status(:not_found)
        |> json(%{
          error: "No mount point found for path",
          path: request_path
        })
    end
  end

  # Private helpers

  defp proxy_to_telephone(conn, path_id, forwarded_path) do
    # Get the path to retrieve timeout configuration
    case Paths.get_path(path_id) do
      nil ->
        Logger.error("Path #{path_id} not found in database")

        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Path configuration not found"})

      path ->
        # Get a telephone from the registry using round-robin
        case TelephoneRegistry.get_telephone(path_id) do
          {:ok, telephone_pid} ->
            # Forward the request to the telephone
            forward_request_to_telephone(conn, telephone_pid, path, forwarded_path)

          {:error, :no_telephone} ->
            Logger.warning("No telephone available for path #{path.full_path}")

            conn
            |> put_status(:service_unavailable)
            |> json(%{
              error: "No telephone available for this path",
              path: path.full_path
            })
        end
    end
  end

  defp forward_request_to_telephone(conn, telephone_pid, path, forwarded_path) do
    timeout = path.request_timeout_ms

    # Generate unique request ID for correlation
    request_id = Ecto.UUID.generate()

    # Read request body
    {:ok, body, conn} = Plug.Conn.read_body(conn)

    # Build request payload for telephone with correlation ID
    request_payload = %{
      "request_id" => request_id,
      "method" => conn.method,
      "path" => forwarded_path,
      "headers" => build_headers_map(conn),
      "body" => body,
      "query_string" => conn.query_string
    }

    # Record start time for telemetry
    start_time = System.monotonic_time()

    # Send request to telephone and wait for response with correlation ID
    task =
      Task.async(fn ->
        send_to_telephone_and_wait(telephone_pid, request_id, request_payload, timeout)
      end)

    case Task.await(task, timeout + 1000) do
      {:ok, response} ->
        # Record telemetry
        duration = System.monotonic_time() - start_time

        :telemetry.execute(
          [:plugboard, :telephone, :proxy_request],
          %{duration: duration},
          %{
            path_id: path.id,
            method: conn.method,
            status: response["status"]
          }
        )

        # Send response back to client
        send_telephone_response(conn, response)

      {:error, :timeout} ->
        Logger.warning("Telephone timeout for path #{path.full_path}")

        :telemetry.execute(
          [:plugboard, :telephone, :proxy_timeout],
          %{count: 1},
          %{path_id: path.id, timeout_ms: timeout}
        )

        conn
        |> put_status(:gateway_timeout)
        |> json(%{
          error: "Telephone response timeout",
          timeout_ms: timeout
        })

      {:error, reason} ->
        Logger.error("Telephone error for path #{path.full_path}: #{inspect(reason)}")

        conn
        |> put_status(:bad_gateway)
        |> json(%{
          error: "Telephone error",
          reason: inspect(reason)
        })
    end
  end

  defp send_to_telephone_and_wait(telephone_pid, request_id, request_payload, timeout) do
    # Check if process is alive before sending (CRITICAL-5 fix)
    if Process.alive?(telephone_pid) do
      # Send the request to the telephone channel process with correlation ID
      send(telephone_pid, {:proxy_request, self(), request_id, request_payload})

      # Wait for response matching the request ID
      receive do
        {:proxy_res, ^request_id, response} ->
          {:ok, response}
      after
        timeout ->
          {:error, :timeout}
      end
    else
      # Process died between lookup and send
      Logger.warning("Telephone process #{inspect(telephone_pid)} is not alive")
      {:error, :telephone_unavailable}
    end
  end

  defp send_telephone_response(conn, response) do
    status = response["status"] || 200
    headers = response["headers"] || %{}
    body = response["body"] || ""

    # Set response headers
    conn =
      Enum.reduce(headers, conn, fn {key, value}, acc_conn ->
        put_resp_header(acc_conn, String.downcase(key), to_string(value))
      end)

    # Send response
    conn
    |> put_status(status)
    |> text(body)
  end

  defp build_headers_map(conn) do
    Enum.into(conn.req_headers, %{})
  end

  defp build_request_path(%{"path" => path_segments}) when is_list(path_segments) do
    "/" <> Enum.join(path_segments, "/")
  end

  defp build_request_path(%{"path" => path}) when is_binary(path) do
    if String.starts_with?(path, "/") do
      path
    else
      "/" <> path
    end
  end

  defp build_request_path(_params) do
    "/"
  end
end
