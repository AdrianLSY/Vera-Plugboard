defmodule PlugboardWeb.Plugs.ValidatePath do
  @moduledoc """
  Plug for validating proxy request paths.

  Validates that path segments are safe and don't contain:
  - Path traversal attempts (../, ..)
  - Null bytes
  - Excessively long segments (> 255 characters)
  - Excessively deep paths (> 50 segments)

  Returns 400 Bad Request if validation fails.
  """

  import Plug.Conn
  require Logger

  alias PlugboardWeb.HTTPError

  @max_segment_length 255
  @max_path_depth 50

  def init(opts), do: opts

  def call(conn, _opts) do
    case validate_path_params(conn.params) do
      :ok ->
        conn

      {:error, reason} ->
        Logger.warning("ValidatePath: Rejected request - #{reason}")

        conn
        |> HTTPError.send_error(400,
          reason: "Invalid path",
          details: %{validation_error: reason},
          log: false
        )
        |> halt()
    end
  end

  defp validate_path_params(%{"path" => path_segments}) when is_list(path_segments) do
    cond do
      length(path_segments) > @max_path_depth ->
        {:error, "Path depth exceeds maximum of #{@max_path_depth} segments"}

      true ->
        validate_segments(path_segments)
    end
  end

  defp validate_path_params(%{"path" => path}) when is_binary(path) do
    # Path might be a string in some cases
    segments = String.split(path, "/", trim: true)
    validate_segments(segments)
  end

  defp validate_path_params(_params) do
    # No path param, let controller handle it
    :ok
  end

  defp validate_segments(segments) do
    Enum.reduce_while(segments, :ok, fn segment, _acc ->
      case validate_segment(segment) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_segment(segment) when byte_size(segment) > @max_segment_length do
    {:error, "Path segment exceeds maximum length of #{@max_segment_length} bytes"}
  end

  defp validate_segment(segment) do
    cond do
      # Check for encoded path traversal (check this first before decoding happens)
      String.contains?(segment, ["%2e%2e", "%2E%2E", "%2e%2E", "%2E%2e"]) ->
        {:error, "Encoded path traversal not allowed"}

      # Check for encoded null bytes
      String.contains?(segment, ["%00", "%00"]) ->
        {:error, "Encoded null bytes not allowed"}

      # Check for path traversal
      String.contains?(segment, ["../", ".."]) ->
        {:error, "Path traversal not allowed"}

      # Check for null bytes
      String.contains?(segment, <<0>>) ->
        {:error, "Null bytes not allowed in path"}

      true ->
        :ok
    end
  end
end
