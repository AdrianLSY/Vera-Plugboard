defmodule PlugboardWeb.Plugs.Parsers do
  @moduledoc """
  A wrapper around Plug.Parsers that reads max body size from runtime config.

  This plug avoids the compile-time warning from using Application.get_env
  in the module body by deferring the config read to runtime.

  ## Configuration

  The `max_request_body_length` value is read from application config:

      config :plugboard, :max_request_body_length, 10_485_760

  This is typically set via the MAX_REQUEST_BODY_SIZE environment variable
  in config/runtime.exs.
  """

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    # Read max body length at runtime
    max_length = Application.get_env(:plugboard, :max_request_body_length, 10_485_760)

    # Configure and call Plug.Parsers with runtime config
    opts =
      Plug.Parsers.init(
        parsers: [:urlencoded, :multipart, :json],
        pass: ["*/*"],
        json_decoder: Phoenix.json_library(),
        length: max_length
      )

    Plug.Parsers.call(conn, opts)
  end
end
