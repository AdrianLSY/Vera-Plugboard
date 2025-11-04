defmodule PlugboardWeb.ProxyController do
  @moduledoc """
  Controller for handling proxy requests to backend telephones.

  This controller receives requests at `/proxies/*path` and routes them to
  the appropriate backend telephone based on the mount point matching.

  ## Error Handling

  The proxy controller implements comprehensive error handling with proper HTTP status codes:

  ### HTTP Status Codes

  - **400 Bad Request**: Invalid path (traversal attempts, excessive depth)
  - **404 Not Found**: No mount point matches the requested path
  - **500 Internal Server Error**: Path configuration errors
  - **502 Bad Gateway**: Telephone errors or disconnections during request
  - **503 Service Unavailable**: No telephone registered for the path
  - **504 Gateway Timeout**: Telephone did not respond within configured timeout

  ### Error Scenarios

  #### Timeout (504)
  When a telephone does not respond within `request_timeout_ms` (default: 60s),
  a 504 Gateway Timeout is returned with details about the timeout duration.

  #### Telephone Unavailable (502/503)
  - **503**: No telephone is currently registered for the path
  - **502**: Telephone was registered but is no longer available (process died)
  - **502**: Telephone disconnected while processing the request

  #### Validation Errors (400)
  Path validation failures (e.g., `../` traversal, excessive depth) return 400
  with details about the validation error.

  ## Streaming Responses

  The proxy controller supports chunked/streaming responses from telephones:

  ### How Streaming Works

  1. Telephone sends response with `"chunked": true` and `"chunks": [...]`
  2. Controller uses `send_chunked/2` and `chunk/2` to stream data to client
  3. Each chunk is sent sequentially with error handling
  4. Chunk errors are logged and emit telemetry events

  ### Streaming Error Handling

  If a chunk fails to send:
  - The error is logged with `Logger.error/1`
  - Telemetry event `[:plugboard, :telephone, :chunk_error]` is emitted
  - Remaining chunks are not sent (response is partial)
  - Client receives what was successfully transmitted

  Note: Once the response status is sent, it cannot be changed. Partial responses
  are logged but the client may receive incomplete data.

  ## Timeout Configuration

  Timeouts are configured per-path in the database:

  - `request_timeout_ms`: Maximum time to wait for telephone response (default: 60000ms)
  - `connect_timeout_ms`: Maximum time to wait for telephone connection (default: 5000ms)

  Invalid timeout values (<= 0 or > 300000ms) are replaced with the default (60000ms)
  and a warning is logged.

  ## Telemetry Events

  The following telemetry events are emitted:

  - `[:plugboard, :telephone, :proxy_request]` - Successful proxy request with duration
  - `[:plugboard, :telephone, :proxy_timeout]` - Request timeout occurred
  - `[:plugboard, :telephone, :slow_response]` - Response took > 80% of timeout
  - `[:plugboard, :telephone, :disconnected]` - Telephone disconnected during request
  - `[:plugboard, :telephone, :unavailable]` - Telephone unavailable when requested
  - `[:plugboard, :telephone, :error]` - General telephone error
  - `[:plugboard, :telephone, :chunk_error]` - Error sending chunk in streaming response

  ## Examples

      # Normal request
      GET /proxies/api/users/123
      -> Routes to telephone mounted at /api
      -> Forwards /users/123 to telephone

      # Timeout scenario
      GET /proxies/slow-api/endpoint
      -> Telephone doesn't respond within timeout
      -> Returns 504 Gateway Timeout

      # No telephone available
      GET /proxies/offline-api/data
      -> No telephone registered for path
      -> Returns 503 Service Unavailable
  """

  use PlugboardWeb, :controller
  require Logger

  alias Plugboard.TelephoneRegistry
  alias Plugboard.Paths
  alias PlugboardWeb.HTTPError

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

        HTTPError.send_error(conn, 404,
          reason: "No mount point found for path",
          details: %{path: request_path},
          log: false
        )
    end
  end

  # Private helpers

  defp proxy_to_telephone(conn, path_id, forwarded_path) do
    # Get the path to retrieve timeout configuration
    case Paths.get_path(path_id) do
      nil ->
        Logger.error("Path #{path_id} not found in database")

        HTTPError.send_error(conn, 500,
          reason: "Path configuration not found",
          details: %{path_id: path_id}
        )

      path ->
        # Get a telephone from the registry using round-robin
        case TelephoneRegistry.get_telephone(path_id) do
          {:ok, telephone_pid} ->
            # Forward the request to the telephone
            forward_request_to_telephone(conn, telephone_pid, path, forwarded_path)

          {:error, :no_telephone} ->
            Logger.warning("No telephone available for path #{path.full_path}")

            HTTPError.send_error(conn, 503,
              reason: "No telephone available for this path",
              details: %{path: path.full_path},
              log: false
            )
        end
    end
  end

  defp forward_request_to_telephone(conn, telephone_pid, path, forwarded_path) do
    timeout = path.request_timeout_ms

    # Validate timeout is reasonable (reassign if invalid)
    timeout =
      if timeout <= 0 or timeout > 300_000 do
        Logger.warning(
          "Invalid timeout #{timeout}ms for path #{path.full_path}, using default 60000ms"
        )

        60_000
      else
        timeout
      end

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

    # Log request initiation
    Logger.debug(
      "Proxying #{conn.method} #{forwarded_path} to telephone for path #{path.full_path} (timeout: #{timeout}ms)"
    )

    # Send request to telephone and wait for response with correlation ID
    task =
      Task.async(fn ->
        send_to_telephone_and_wait(telephone_pid, request_id, request_payload, timeout)
      end)

    case Task.await(task, timeout + 1000) do
      {:ok, response} ->
        # Record telemetry
        duration = System.monotonic_time() - start_time
        duration_ms = System.convert_time_unit(duration, :native, :millisecond)

        :telemetry.execute(
          [:plugboard, :telephone, :proxy_request],
          %{duration: duration},
          %{
            path_id: path.id,
            method: conn.method,
            status: response["status"]
          }
        )

        # Warn if request took more than 80% of timeout
        if duration_ms > timeout * 0.8 do
          Logger.warning(
            "Slow telephone response: #{duration_ms}ms (#{Float.round(duration_ms / timeout * 100, 1)}% of timeout) for #{conn.method} #{forwarded_path}"
          )

          :telemetry.execute(
            [:plugboard, :telephone, :slow_response],
            %{duration: duration, timeout: timeout},
            %{path_id: path.id, method: conn.method}
          )
        end

        # Send response back to client
        send_telephone_response(conn, response)

      {:error, :timeout} ->
        Logger.warning("Telephone timeout for path #{path.full_path}")

        :telemetry.execute(
          [:plugboard, :telephone, :proxy_timeout],
          %{count: 1},
          %{path_id: path.id, timeout_ms: timeout}
        )

        HTTPError.send_error(conn, 504,
          reason: "Gateway Timeout - The telephone did not respond in time",
          details: %{
            path: path.full_path,
            timeout_ms: timeout,
            forwarded_path: forwarded_path
          },
          log: false
        )

      {:error, :telephone_unavailable} ->
        Logger.error("Telephone unavailable for path #{path.full_path}")

        :telemetry.execute(
          [:plugboard, :telephone, :unavailable],
          %{count: 1},
          %{path_id: path.id}
        )

        HTTPError.send_error(conn, 502,
          reason: "Bad Gateway - Telephone disconnected",
          details: %{
            path: path.full_path,
            forwarded_path: forwarded_path
          },
          log: false
        )

      {:error, :telephone_disconnected} ->
        Logger.error("Telephone disconnected during request for path #{path.full_path}")

        :telemetry.execute(
          [:plugboard, :telephone, :disconnected],
          %{count: 1},
          %{path_id: path.id}
        )

        HTTPError.send_error(conn, 502,
          reason: "Bad Gateway - Telephone disconnected during request",
          details: %{
            path: path.full_path,
            forwarded_path: forwarded_path
          },
          log: false
        )

      {:error, reason} ->
        Logger.error("Telephone error for path #{path.full_path}: #{inspect(reason)}")

        :telemetry.execute(
          [:plugboard, :telephone, :error],
          %{count: 1},
          %{path_id: path.id, reason: reason}
        )

        HTTPError.send_error(conn, 502,
          reason: "Bad Gateway - Telephone error",
          details: %{
            path: path.full_path,
            error: inspect(reason),
            forwarded_path: forwarded_path
          },
          log: false
        )
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

        {:proxy_error, ^request_id, :telephone_disconnected} ->
          # Telephone disconnected while we were waiting
          {:error, :telephone_disconnected}

        {:proxy_error, ^request_id, reason} ->
          # Other telephone errors
          {:error, reason}
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
    is_chunked = response["chunked"] || false
    chunks = response["chunks"] || []

    # Set response headers
    conn =
      Enum.reduce(headers, conn, fn {key, value}, acc_conn ->
        put_resp_header(acc_conn, String.downcase(key), to_string(value))
      end)

    # Handle chunked/streaming responses
    if is_chunked and length(chunks) > 0 do
      send_chunked_response(conn, status, chunks)
    else
      # Send regular response
      conn
      |> put_status(status)
      |> text(body)
    end
  end

  defp send_chunked_response(conn, status, chunks) do
    conn =
      conn
      |> put_status(status)
      |> send_chunked(status)

    # Send each chunk and handle errors
    result =
      Enum.reduce_while(chunks, {:ok, conn}, fn chunk, {:ok, acc_conn} ->
        case chunk(acc_conn, chunk) do
          {:ok, new_conn} ->
            {:cont, {:ok, new_conn}}

          {:error, reason} ->
            Logger.error("Error sending chunk: #{inspect(reason)}")

            :telemetry.execute(
              [:plugboard, :telephone, :chunk_error],
              %{count: 1},
              %{reason: reason}
            )

            {:halt, {:error, reason, acc_conn}}
        end
      end)

    case result do
      {:ok, conn} ->
        conn

      {:error, reason, conn} ->
        # Partial response already sent, can't change status
        # Log the error for monitoring
        Logger.error("Failed to send complete chunked response: #{inspect(reason)}")
        conn
    end
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
