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

  alias PlugboardWeb.HTTPError

  @max_segment_length 255
  @max_path_depth 50

  def init(opts), do: opts

  def call(conn, _opts) do
    case validate_path_params(conn.params) do
      :ok ->
        conn

      {:error, reason} ->
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
    if length(path_segments) > @max_path_depth do
      {:error, "Path depth exceeds maximum of #{@max_path_depth} segments"}
    else
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
    # First check the raw segment
    case validate_raw_segment(segment) do
      :ok ->
        # Also validate the decoded version to catch encoded attacks
        # We decode recursively to handle double/triple encoding
        case validate_decoded_segment(segment, 3) do
          :ok -> :ok
          error -> error
        end

      error ->
        error
    end
  end

  # Validate raw segment (before decoding)
  defp validate_raw_segment(segment) do
    cond do
      # Check for path traversal patterns
      String.contains?(segment, ["../", ".."]) ->
        {:error, "Path traversal not allowed"}

      # Check for null bytes
      String.contains?(segment, <<0>>) ->
        {:error, "Null bytes not allowed in path"}

      # Check for backslash path traversal (Windows-style)
      String.contains?(segment, ["..\\", "..\\"]) ->
        {:error, "Path traversal not allowed"}

      true ->
        :ok
    end
  end

  # Recursively decode and validate to catch multi-level encoding attacks
  # Continue decoding until the string no longer changes (fully decoded)
  defp validate_decoded_segment(segment, max_iterations) do
    do_validate_decoded(segment, segment, max_iterations)
  end

  defp do_validate_decoded(_original, _current, 0) do
    # Maximum iterations reached without stabilizing - suspicious input
    {:error, "Excessive URL encoding detected"}
  end

  defp do_validate_decoded(original, current, iterations_left) do
    # Decode the segment
    decoded =
      try do
        URI.decode(current)
      rescue
        _ -> current
      end

    # If decoding didn't change anything, we've fully decoded
    if decoded == current do
      # Now validate the fully decoded segment
      validate_fully_decoded_segment(decoded)
    else
      # Validate intermediate state for early rejection
      case validate_intermediate_segment(decoded) do
        :ok ->
          # Continue decoding
          do_validate_decoded(original, decoded, iterations_left - 1)

        error ->
          error
      end
    end
  end

  # Validate intermediate decoding state
  defp validate_intermediate_segment(segment) do
    cond do
      # Check for path traversal patterns
      segment == ".." ->
        {:error, "Encoded path traversal not allowed"}

      String.contains?(segment, ["../", "..\\", "..\\"]) ->
        {:error, "Encoded path traversal not allowed"}

      # Check for null bytes
      String.contains?(segment, <<0>>) ->
        {:error, "Encoded null bytes not allowed"}

      true ->
        :ok
    end
  end

  # Validate the fully decoded segment
  defp validate_fully_decoded_segment(segment) do
    cond do
      # Exact match for ".."
      segment == ".." ->
        {:error, "Path traversal not allowed"}

      # Check for traversal patterns
      String.contains?(segment, ["../", "..\\", "..\\"]) ->
        {:error, "Path traversal not allowed"}

      # Starts with ".." followed by any separator
      String.starts_with?(segment, "..") ->
        {:error, "Path traversal not allowed"}

      # Ends with ".."
      String.ends_with?(segment, "/..") or String.ends_with?(segment, "\\..") ->
        {:error, "Path traversal not allowed"}

      # Check for null bytes
      String.contains?(segment, <<0>>) ->
        {:error, "Null bytes not allowed in path"}

      true ->
        :ok
    end
  end
end
