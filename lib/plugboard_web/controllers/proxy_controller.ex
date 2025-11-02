defmodule PlugboardWeb.ProxyController do
  @moduledoc """
  Controller for handling proxy requests to backend agents.

  This controller receives requests at `/proxies/*path` and routes them to
  the appropriate backend agent based on the mount point matching.

  For Phase 2, this controller returns placeholder responses showing which
  mount point matched and what the forwarded path would be. In Phase 3,
  this will be replaced with actual WebSocket-based proxying to agents.
  """

  use PlugboardWeb, :controller
  require Logger

  @doc """
  Handles all proxy requests.

  Routing logic:
  1. Extract the request path after `/proxies/`
  2. Use MountStore.match/1 to find a matching mount point
  3. If match found, return mount info (Phase 2) or proxy to agent (Phase 3+)
  4. If no match, return 404
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

        # Phase 2: Return placeholder response showing mount info
        # Phase 3+: This will proxy to the actual agent via WebSocket
        conn
        |> put_status(:ok)
        |> json(%{
          status: "matched",
          mount_path: mount_path,
          mount_id: mount_id,
          forwarded_path: forwarded_path,
          original_request: request_path,
          message:
            "Phase 2: Mount matched successfully. Agent proxying will be implemented in Phase 3."
        })

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
