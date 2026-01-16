defmodule Plugboard.Hooks.Executor do
  @moduledoc """
  Executes hooks sequentially and merges responses into request body.

  Hooks are executed in order (by execution_order field) and each hook
  receives the accumulated request body from all previous hooks.

  Hook responses are merged at the root level using Map.merge/2,
  with the hook response winning on key conflicts.
  """

  require Logger
  alias Plugboard.HookStore
  alias Plugboard.TelephoneRegistry
  alias Plugboard.MountStore
  alias Plugboard.Paths
  alias Plugboard.Hooks.Hook

  # Type definitions
  @type path_id :: String.t()
  @type hook_error_response :: %{status: integer(), body: String.t()}
  @type execute_result ::
          {:ok, Plug.Conn.t()}
          | {:error, :rejected, Hook.t(), hook_error_response()}
          | {:error, :timeout, Hook.t(), nil}
          | {:error, :unavailable, Hook.t(), nil}

  @doc """
  Executes all hooks for a path and returns the modified connection.

  Returns:
    - {:ok, conn_with_modified_body} on success
    - {:error, :hook_rejected, hook, response} on hook failure
    - {:error, :timeout, hook} on timeout
    - {:error, :unavailable, hook} on connection error
  """
  @spec execute_hooks(Plug.Conn.t(), path_id()) :: execute_result()
  def execute_hooks(conn, path_id) do
    hooks = HookStore.get_hooks(path_id)

    if Enum.empty?(hooks) do
      {:ok, conn}
    else
      # Read original request body
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      # Parse JSON (or use empty map if body is empty)
      initial_body = parse_body(body)

      # Execute hooks sequentially
      case execute_hook_chain(conn, hooks, initial_body) do
        {:ok, final_body} ->
          # Replace conn body with merged result
          modified_conn = put_modified_body(conn, final_body)
          {:ok, modified_conn}

        error ->
          error
      end
    end
  end

  # Private functions

  defp execute_hook_chain(conn, hooks, accumulated_body) do
    Enum.reduce_while(hooks, {:ok, accumulated_body}, fn hook, {:ok, body} ->
      case execute_single_hook(conn, hook, body) do
        {:ok, hook_response_body} ->
          # Merge hook response into accumulated body (root level merge)
          merged_body = Map.merge(body, hook_response_body)

          Logger.debug(
            "Hook #{hook.name} (#{hook.id}) succeeded, merged #{map_size(hook_response_body)} keys"
          )

          {:cont, {:ok, merged_body}}

        {:error, reason, response} ->
          {:halt, {:error, reason, hook, response}}
      end
    end)
  end

  defp execute_single_hook(conn, hook, body) do
    start_time = System.monotonic_time()

    result =
      case hook.target_type do
        "mount_point" ->
          execute_mount_point_hook(conn, hook, body)

        "http_url" ->
          execute_http_hook(conn, hook, body)
      end

    handle_hook_response(result, hook, start_time)
  end

  defp execute_mount_point_hook(conn, hook, body) do
    # Get target path details
    case Paths.get_path(hook.target_path_id) do
      nil ->
        Logger.error("Hook #{hook.name}: target path #{hook.target_path_id} not found")
        {:error, :unavailable}

      target_path ->
        # Match against mount store to get telephone
        case MountStore.match(target_path.full_path) do
          {:ok, {_mount_path, forwarded_path, mount_id}} ->
            case TelephoneRegistry.get_telephone(mount_id) do
              {:ok, telephone_pid} ->
                # Build request payload
                payload = build_hook_payload(conn, hook, body, forwarded_path)

                # Send to telephone and wait for response
                send_to_telephone_and_wait(
                  telephone_pid,
                  payload,
                  hook.timeout_ms
                )

              {:error, :no_telephone} ->
                Logger.warning(
                  "Hook #{hook.name}: no telephone available for mount #{target_path.full_path}"
                )

                {:error, :unavailable}
            end

          {:error, :not_found} ->
            Logger.error("Hook #{hook.name}: mount point #{target_path.full_path} not found")
            {:error, :unavailable}
        end
    end
  end

  defp execute_http_hook(conn, hook, body) do
    # Build HTTP request
    headers = build_http_headers(conn, hook)
    json_body = Jason.encode!(body)

    # Make HTTP POST request using Req
    case Req.post(
           hook.target_url,
           body: json_body,
           headers: headers,
           receive_timeout: hook.timeout_ms,
           retry: false
         ) do
      {:ok, %Req.Response{status: status, body: response_body}} ->
        {:ok, status, response_body}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, :timeout}

      {:error, %Req.TransportError{}} ->
        {:error, :unavailable}

      {:error, _reason} ->
        {:error, :unavailable}
    end
  end

  defp handle_hook_response({:ok, status, response_body}, hook, start_time) do
    duration = System.monotonic_time() - start_time

    # Emit telemetry
    :telemetry.execute(
      [:plugboard, :hook, :executed],
      %{duration: duration},
      %{
        hook_id: hook.id,
        hook_name: hook.name,
        status: status,
        allowed: status in hook.allowed_status_codes
      }
    )

    if status in hook.allowed_status_codes do
      # Success - parse and return response body
      case parse_hook_response(response_body) do
        {:ok, parsed_body} when is_map(parsed_body) ->
          {:ok, parsed_body}

        {:ok, _non_map} ->
          Logger.warning("Hook #{hook.name} returned non-object JSON, ignoring")
          {:ok, %{}}

        {:error, _} ->
          Logger.warning("Hook #{hook.name} returned invalid JSON, ignoring")
          {:ok, %{}}
      end
    else
      # Hook rejected - return error with hook's response
      Logger.info("Hook #{hook.name} rejected request with status #{status}")
      {:error, :rejected, %{status: status, body: response_body}}
    end
  end

  defp handle_hook_response({:error, :timeout}, hook, start_time) do
    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:plugboard, :hook, :timeout],
      %{duration: duration},
      %{hook_id: hook.id, hook_name: hook.name}
    )

    Logger.warning("Hook #{hook.name} timed out after #{hook.timeout_ms}ms")
    {:error, :timeout, nil}
  end

  defp handle_hook_response({:error, :unavailable}, hook, _start_time) do
    :telemetry.execute(
      [:plugboard, :hook, :unavailable],
      %{count: 1},
      %{hook_id: hook.id, hook_name: hook.name}
    )

    Logger.warning("Hook #{hook.name} unavailable")
    {:error, :unavailable, nil}
  end

  defp build_hook_payload(conn, hook, body, forwarded_path) do
    headers = build_hook_headers(conn, hook)

    %{
      "request_id" => Ecto.UUID.generate(),
      "method" => "POST",
      "path" => forwarded_path,
      "headers" => headers,
      "body" => Jason.encode!(body),
      "query_string" => if(hook.forward_query_params, do: conn.query_string, else: "")
    }
  end

  defp build_hook_headers(conn, hook) do
    base_headers = %{
      "content-type" => "application/json",
      "x-original-method" => conn.method,
      "x-original-path" => conn.request_path,
      "x-hook-id" => hook.id,
      "x-hook-name" => hook.name
    }

    # Add headers from forward_headers config
    forwarded =
      hook.forward_headers
      |> Enum.reduce(%{}, fn header_name, acc ->
        case Plug.Conn.get_req_header(conn, String.downcase(header_name)) do
          [value | _] -> Map.put(acc, String.downcase(header_name), value)
          [] -> acc
        end
      end)

    Map.merge(base_headers, forwarded)
  end

  defp build_http_headers(conn, hook) do
    hook_headers = build_hook_headers(conn, hook)

    # Convert to list of tuples for Req
    Enum.map(hook_headers, fn {k, v} -> {k, v} end)
  end

  defp parse_body(""), do: %{}

  defp parse_body(body) do
    case Jason.decode(body) do
      {:ok, parsed} when is_map(parsed) -> parsed
      _ -> %{}
    end
  end

  defp parse_hook_response(body) when is_binary(body) do
    Jason.decode(body)
  end

  defp parse_hook_response(body) when is_map(body) do
    # Req might already decode JSON
    {:ok, body}
  end

  defp parse_hook_response(_body) do
    {:error, :invalid_format}
  end

  # Updates the connection with the modified body after hook execution.
  #
  # IMPORTANT: Body Consumption Pattern
  # -----------------------------------
  # At this point, the original request body has already been consumed by
  # `Plug.Conn.read_body/1` in `execute_hooks/2`. Since Plug only allows
  # reading the body once, we store the modified body in two places:
  #
  # 1. `conn.body_params` - For code that accesses parsed body params
  # 2. `conn.private[:raw_body]` - For code that needs the raw JSON string
  #
  # The ProxyController handles this by calling `read_request_body/3` which
  # reads from the connection body (for requests without hooks) or could be
  # extended to read from `conn.private[:raw_body]` if hooks modified it.
  #
  # Currently, ProxyController.forward_request_to_telephone/4 calls
  # read_request_body/3 AFTER hooks execute, so the original body reading
  # in execute_hooks/2 consumes the body first. This works because
  # ProxyController receives the already-modified conn from execute_hooks.
  defp put_modified_body(conn, body) do
    json_body = Jason.encode!(body)

    conn
    |> Map.put(:body_params, body)
    |> Plug.Conn.put_private(:raw_body, json_body)
  end

  defp send_to_telephone_and_wait(telephone_pid, payload, timeout) do
    request_id = payload["request_id"]

    if Process.alive?(telephone_pid) do
      send(telephone_pid, {:proxy_request, self(), request_id, payload})

      receive do
        {:proxy_res, ^request_id, response} ->
          {:ok, response["status"], response["body"]}

        {:proxy_error, ^request_id, _reason} ->
          {:error, :unavailable}
      after
        timeout ->
          {:error, :timeout}
      end
    else
      {:error, :unavailable}
    end
  end
end
