defmodule PlugboardWeb.HTTPError do
  @moduledoc """
  Handles HTTP error responses with images.

  This module provides utilities to send standardized error responses with
  associated HTTP status code images for visual feedback.

  ## Overview

  HTTPError centralizes error response formatting for the Plugboard application,
  providing consistent, visually appealing error pages with contextual information.

  ## Features

  - **Visual Error Pages**: HTML responses with HTTP status code images
  - **Detailed Context**: Include error reasons and structured details
  - **JSON Alternative**: API-friendly JSON error responses
  - **Configurable Logging**: Control error logging per response
  - **Fallback Images**: Graceful degradation when status-specific images don't exist

  ## HTTP Status Code Strategy

  The application uses the following status codes:

  - **400 Bad Request**: Invalid client input (path validation, malformed requests)
  - **404 Not Found**: Resource not found (no matching mount point)
  - **500 Internal Server Error**: Server configuration or internal errors
  - **502 Bad Gateway**: Backend telephone errors or disconnections
  - **503 Service Unavailable**: No backend telephone available
  - **504 Gateway Timeout**: Backend timeout (telephone didn't respond)

  ## Error Response Format

  HTML responses include:
  - Large, styled status code display
  - Human-readable error reason
  - HTTP status code image (if available)
  - Structured error details (for debugging)
  - Consistent dark theme styling

  ## Usage Examples

      # Simple error with default reason
      HTTPError.send_error(conn, 404)

      # Error with custom reason
      HTTPError.send_error(conn, 503,
        reason: "No telephone available for this path")

      # Error with details (for debugging)
      HTTPError.send_error(conn, 504,
        reason: "Gateway Timeout",
        details: %{
          path: "/api/users",
          timeout_ms: 60000
        })

      # Error without logging (for expected scenarios)
      HTTPError.send_error(conn, 404,
        reason: "Mount point not found",
        log: false)

      # JSON error response
      HTTPError.send_json_error(conn, 400,
        reason: "Invalid request",
        details: %{field: "path"})

  ## Image Assets

  Status code images are located in `public/img/http/` and are named by status code
  (e.g., `404.jpg`, `502.jpg`). If a specific image doesn't exist, the system falls
  back to `0.jpg` as a generic error image.
  """

  import Plug.Conn

  alias Plug.Conn.Status

  # Type definitions
  @type status :: integer() | atom()
  @type error_opts :: [
          reason: String.t(),
          details: map(),
          log: boolean()
        ]

  @http_images_path "public/img/http"

  @doc """
  Sends an HTTP error response with status code and associated image.

  This is the primary function for sending error responses in the Plugboard application.
  It generates a styled HTML page with the error details and attempts to include a
  relevant image for the status code.

  ## Parameters

  - `conn` - The Plug connection struct
  - `status` - HTTP status code (integer like `404` or atom like `:not_found`)
  - `opts` - Keyword list of options:
    - `:reason` - Human-readable error message (optional, defaults based on status)
    - `:details` - Map of additional context for debugging (optional)
    - `:log` - Whether to log the error (default: `true`, set to `false` for expected errors)

  ## Return Value

  Returns the connection with the error response sent.

  ## Logging Behavior

  - Errors with status >= 500 are logged at `:error` level
  - Errors with status < 500 are logged at `:warning` level
  - Logging can be disabled by passing `log: false` (useful for expected errors like 404)

  ## Examples

      # Basic 404 error
      send_error(conn, 404)

      # Service unavailable with custom message
      send_error(conn, 503, reason: "No telephone available for this path")

      # Timeout with debug details
      send_error(conn, 504,
        reason: "Gateway Timeout - The telephone did not respond in time",
        details: %{path: "/api/users", timeout_ms: 60000, forwarded_path: "/users"})

      # Expected error without logging
      send_error(conn, 404, reason: "Mount point not found", log: false)

      # Using atom status code
      send_error(conn, :service_unavailable, reason: "System maintenance")
  """
  @spec send_error(Plug.Conn.t(), status(), error_opts()) :: Plug.Conn.t()
  def send_error(conn, status, opts \\ []) do
    status_code = normalize_status(status)
    reason = Keyword.get(opts, :reason, default_reason(status_code))
    details = Keyword.get(opts, :details, %{})
    _should_log = Keyword.get(opts, :log, true)

    # Check if we have an image for this status code
    image_path = image_path_for_status(status_code)

    conn
    |> put_status(status_code)
    |> put_resp_content_type("text/html")
    |> send_resp(status_code, render_error_html(status_code, reason, details, image_path))
  end

  @doc """
  Sends a JSON error response without images.

  This function is useful for API clients or programmatic access where JSON
  is preferred over HTML. The response structure is consistent and machine-readable.

  ## Parameters

  - `conn` - The Plug connection struct
  - `status` - HTTP status code (integer or atom)
  - `opts` - Keyword list of options (same as `send_error/3`)

  ## Response Format

  The JSON response has the following structure:

      {
        "error": "Human readable error message",
        "status": 404,
        "details": {  // Optional, only if provided
          "key": "value"
        }
      }

  ## Examples

      # Simple JSON error
      send_json_error(conn, 400, reason: "Invalid request")
      # => {"error": "Invalid request", "status": 400}

      # With details
      send_json_error(conn, 422,
        reason: "Validation failed",
        details: %{field: "email", error: "invalid format"})
      # => {"error": "Validation failed", "status": 422, "details": {...}}
  """
  @spec send_json_error(Plug.Conn.t(), status(), error_opts()) :: Plug.Conn.t()
  def send_json_error(conn, status, opts \\ []) do
    status_code = normalize_status(status)
    reason = Keyword.get(opts, :reason, default_reason(status_code))
    details = Keyword.get(opts, :details, %{})

    error_body =
      %{
        error: reason,
        status: status_code
      }
      |> maybe_add_details(details)

    conn
    |> put_status(status_code)
    |> Phoenix.Controller.json(error_body)
  end

  @doc """
  Determines if an image exists for the given status code.

  Checks the filesystem for a JPEG image matching the status code in the
  `public/img/http/` directory.

  ## Parameters

  - `status_code` - Integer HTTP status code (e.g., 404, 502)

  ## Returns

  Boolean indicating whether an image file exists for this status code.

  ## Examples

      has_image?(404)
      # => true (if public/img/http/404.jpg exists)

      has_image?(999)
      # => false (likely no image for this code)
  """
  @spec has_image?(integer()) :: boolean()
  def has_image?(status_code) do
    image_path =
      Path.join([
        File.cwd!(),
        @http_images_path,
        "#{status_code}.jpg"
      ])

    File.exists?(image_path)
  end

  # Private functions

  defp normalize_status(status) when is_integer(status), do: status

  defp normalize_status(status) when is_atom(status) do
    Status.code(status)
  end

  defp default_reason(400), do: "Bad Request"
  defp default_reason(401), do: "Unauthorized"
  defp default_reason(403), do: "Forbidden"
  defp default_reason(404), do: "Not Found"
  defp default_reason(408), do: "Request Timeout"
  defp default_reason(500), do: "Internal Server Error"
  defp default_reason(501), do: "Not Implemented"
  defp default_reason(502), do: "Bad Gateway"
  defp default_reason(503), do: "Service Unavailable"
  defp default_reason(504), do: "Gateway Timeout"
  defp default_reason(status), do: "HTTP Error #{status}"

  defp image_path_for_status(status_code) do
    if has_image?(status_code) do
      "/img/http/#{status_code}.jpg"
    else
      # Fallback to 0.jpg if specific status image doesn't exist
      if has_image?(0) do
        "/img/http/0.jpg"
      else
        nil
      end
    end
  end

  defp render_error_html(status_code, reason, details, image_path) do
    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="UTF-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      <title>#{status_code} - #{reason}</title>
      <style>
        * {
          margin: 0;
          padding: 0;
          box-sizing: border-box;
        }
        body {
          font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
          background-color: #0f0f0f;
          color: #e0e0e0;
          display: flex;
          flex-direction: column;
          align-items: center;
          justify-content: center;
          min-height: 100vh;
          padding: 2rem;
          line-height: 1.6;
        }
        .container {
          max-width: 800px;
          width: 100%;
          text-align: center;
        }
        .status-code {
          font-size: 6rem;
          font-weight: 700;
          color: #ff6b6b;
          margin-bottom: 1rem;
          text-shadow: 0 0 20px rgba(255, 107, 107, 0.3);
        }
        .reason {
          font-size: 2rem;
          font-weight: 500;
          margin-bottom: 2rem;
          color: #f0f0f0;
        }
        .image-container {
          margin: 2rem 0;
          border-radius: 8px;
          overflow: hidden;
          box-shadow: 0 4px 20px rgba(0, 0, 0, 0.5);
        }
        .image-container img {
          max-width: 100%;
          height: auto;
          display: block;
        }
        .details {
          background-color: #1a1a1a;
          border: 1px solid #333;
          border-radius: 8px;
          padding: 1.5rem;
          margin-top: 2rem;
          text-align: left;
        }
        .details-title {
          font-size: 1.2rem;
          font-weight: 600;
          margin-bottom: 1rem;
          color: #ff6b6b;
        }
        .details-content {
          font-family: "Courier New", Courier, monospace;
          font-size: 0.9rem;
          color: #b0b0b0;
          white-space: pre-wrap;
          word-break: break-all;
        }
        .footer {
          margin-top: 3rem;
          font-size: 0.9rem;
          color: #666;
        }
        @media (max-width: 600px) {
          .status-code {
            font-size: 4rem;
          }
          .reason {
            font-size: 1.5rem;
          }
        }
      </style>
    </head>
    <body>
      <div class="container">
        <div class="status-code">#{status_code}</div>
        <div class="reason">#{html_escape_text(reason)}</div>
        #{if image_path, do: render_image(image_path), else: ""}
        #{if map_size(details) > 0, do: render_details(details), else: ""}
        <div class="footer">Plugboard Proxy</div>
      </div>
    </body>
    </html>
    """
  end

  defp render_image(image_path) do
    """
    <div class="image-container">
      <img src="#{image_path}" alt="HTTP Status Illustration" />
    </div>
    """
  end

  defp render_details(details) when is_map(details) do
    formatted_details =
      Enum.map_join(details, "\n", fn {key, value} -> "#{key}: #{inspect(value)}" end)

    """
    <div class="details">
      <div class="details-title">Error Details</div>
      <div class="details-content">#{html_escape_text(formatted_details)}</div>
    </div>
    """
  end

  defp maybe_add_details(error_body, details) when map_size(details) == 0, do: error_body
  defp maybe_add_details(error_body, details), do: Map.put(error_body, :details, details)

  # Simple HTML escaping for text content
  defp html_escape_text(text) do
    text
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end
end
