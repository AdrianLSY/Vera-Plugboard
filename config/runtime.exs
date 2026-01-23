import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/plugboard start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :plugboard, PlugboardWeb.Endpoint, server: true
end

if config_env() == :prod do
  database_url =
    (fn ->
       user = System.get_env("POSTGRES_USER") || raise "POSTGRES_USER is missing"
       password = System.get_env("POSTGRES_PASSWORD") || raise "POSTGRES_PASSWORD is missing"
       host = System.get_env("POSTGRES_HOST") || raise "POSTGRES_HOST is missing"
       port = System.get_env("POSTGRES_PORT") || "5432"
       database = System.get_env("POSTGRES_DB") || raise "POSTGRES_DB is missing"
       "postgresql://#{user}:#{password}@#{host}:#{port}/#{database}"
     end).()

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  # Database SSL configuration
  # DATABASE_SSL: Enable SSL for database connections. Default: true
  # Set to "false" only for local development or trusted networks
  db_ssl = System.get_env("DATABASE_SSL", "true") == "true"

  db_opts = [
    url: database_url,
    pool_size: String.to_integer(System.get_env("DB_POOL_SIZE")),
    socket_options: maybe_ipv6,
    # Query and connection timeouts for production
    timeout: String.to_integer(System.get_env("DB_QUERY_TIMEOUT")),
    connect_timeout: String.to_integer(System.get_env("DB_CONNECT_TIMEOUT"))
  ]

  db_opts =
    if db_ssl do
      Keyword.merge(db_opts,
        ssl: true,
        ssl_opts: [
          verify: :verify_peer,
          cacerts: :public_key.cacerts_get(),
          customize_hostname_check: [
            match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
          ]
        ]
      )
    else
      db_opts
    end

  config :plugboard, Plugboard.Repo, db_opts

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST")
  port = String.to_integer(System.get_env("PHX_PORT"))

  config :plugboard, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # Session and LiveView signing salts - required in production
  session_signing_salt =
    System.get_env("SESSION_SIGNING_SALT") ||
      raise """
      environment variable SESSION_SIGNING_SALT is missing.
      You can generate one by calling: mix phx.gen.secret 32
      """

  live_view_signing_salt =
    System.get_env("LIVE_VIEW_SIGNING_SALT") ||
      raise """
      environment variable LIVE_VIEW_SIGNING_SALT is missing.
      You can generate one by calling: mix phx.gen.secret 32
      """

  # Optional: Session encryption salt for additional security
  session_encryption_salt = System.get_env("SESSION_ENCRYPTION_SALT")

  # HTTPS enforcement: redirect all HTTP traffic to HTTPS
  # FORCE_SSL: Enable force_ssl. Default: true
  # Set to "false" only if running behind a TLS-terminating load balancer
  force_ssl = System.get_env("FORCE_SSL", "true") == "true"

  endpoint_opts = [
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base,
    live_view: [signing_salt: live_view_signing_salt]
  ]

  endpoint_opts =
    if force_ssl do
      Keyword.put(endpoint_opts, :force_ssl,
        hsts: true,
        rewrite_on: [:x_forwarded_proto]
      )
    else
      endpoint_opts
    end

  config :plugboard, PlugboardWeb.Endpoint, endpoint_opts

  config :plugboard, :session,
    signing_salt: session_signing_salt,
    encryption_salt: session_encryption_salt

  # Mark as production environment for secure cookie flag
  config :plugboard, :env, :prod

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :plugboard, PlugboardWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :plugboard, PlugboardWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :plugboard, Plugboard.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://hexdocs.pm/swoosh/Swoosh.html#module-installation for details.
end

# =============================================================================
# Configuration for dev and prod environments
# Test environment uses explicit values from config/test.exs for determinism
# =============================================================================
if config_env() != :test do
  # MountStore configuration
  # MOUNT_STORE_RECONCILE_INTERVAL: How often to reconcile mount points with DB (ms)
  # Default: 300000 (5 minutes)
  config :plugboard, Plugboard.MountStore,
    reconcile_interval:
      (System.get_env("MOUNT_STORE_RECONCILE_INTERVAL") || "300000") |> String.to_integer()

  # HookStore configuration
  # HOOK_STORE_RECONCILE_INTERVAL: How often to reconcile hooks with DB (ms)
  # Default: 300000 (5 minutes)
  config :plugboard, Plugboard.HookStore,
    reconcile_interval:
      (System.get_env("HOOK_STORE_RECONCILE_INTERVAL") || "300000") |> String.to_integer()

  # Telephone token configuration
  # TELEPHONE_TOKEN_EXPIRY: Token validity duration (seconds). Default: 3600 (1 hour)
  # TELEPHONE_TOKEN_REFRESH_INTERVAL: How often clients should refresh (seconds). Default: 1800 (30 min)
  # TELEPHONE_HEARTBEAT_TIMEOUT_MS: Heartbeat timeout before disconnect (ms). Default: 60000 (60 sec)
  config :plugboard, :telephone,
    token_expiry: (System.get_env("TELEPHONE_TOKEN_EXPIRY") || "3600") |> String.to_integer(),
    token_refresh_interval:
      (System.get_env("TELEPHONE_TOKEN_REFRESH_INTERVAL") || "1800") |> String.to_integer(),
    heartbeat_timeout_ms:
      (System.get_env("TELEPHONE_HEARTBEAT_TIMEOUT_MS") || "60000") |> String.to_integer()

  # Request body size limit (in bytes)
  # MAX_REQUEST_BODY_SIZE: Maximum request body size. Default: 10485760 (10MB)
  config :plugboard,
         :max_request_body_length,
         (System.get_env("MAX_REQUEST_BODY_SIZE") || "10485760") |> String.to_integer()

  # WebSocket proxy configuration
  # WEBSOCKET_PROXY_ENABLED: Enable/disable WebSocket proxying. Default: true
  # WEBSOCKET_CHECK_TIMEOUT_MS: Timeout for backend WebSocket check (pre-connection). Default: 5000 (5 sec)
  # WEBSOCKET_CONNECT_TIMEOUT_MS: Timeout for backend WebSocket connection. Default: 5000 (5 sec)
  # WEBSOCKET_MAX_FRAME_SIZE: Maximum WebSocket frame size in bytes. Default: 1048576 (1MB)
  # WEBSOCKET_IDLE_TIMEOUT_MS: Idle timeout before closing connection. Default: 300000 (5 min)
  config :plugboard, :websocket_proxy,
    enabled: (System.get_env("WEBSOCKET_PROXY_ENABLED") || "true") == "true",
    check_timeout_ms:
      (System.get_env("WEBSOCKET_CHECK_TIMEOUT_MS") || "5000") |> String.to_integer(),
    connect_timeout_ms:
      (System.get_env("WEBSOCKET_CONNECT_TIMEOUT_MS") || "5000") |> String.to_integer(),
    max_frame_size:
      (System.get_env("WEBSOCKET_MAX_FRAME_SIZE") || "1048576") |> String.to_integer(),
    idle_timeout_ms:
      (System.get_env("WEBSOCKET_IDLE_TIMEOUT_MS") || "300000") |> String.to_integer()

  # Rate Limiting Configuration
  # RATE_LIMIT_AUTH_LIMIT: Max auth requests per window. Default: 5
  # RATE_LIMIT_AUTH_WINDOW_MS: Auth window duration (ms). Default: 60000 (1 min)
  # RATE_LIMIT_API_LIMIT: Max API requests per window. Default: 100
  # RATE_LIMIT_API_WINDOW_MS: API window duration (ms). Default: 60000 (1 min)
  # RATE_LIMIT_PROXY_LIMIT: Max proxy requests per window. Default: 10000
  # RATE_LIMIT_PROXY_WINDOW_MS: Proxy window duration (ms). Default: 60000 (1 min)
  config :plugboard, Plugboard.RateLimiter,
    auth_limit: (System.get_env("RATE_LIMIT_AUTH_LIMIT") || "5") |> String.to_integer(),
    auth_window_ms:
      (System.get_env("RATE_LIMIT_AUTH_WINDOW_MS") || "60000") |> String.to_integer(),
    api_limit: (System.get_env("RATE_LIMIT_API_LIMIT") || "100") |> String.to_integer(),
    api_window_ms: (System.get_env("RATE_LIMIT_API_WINDOW_MS") || "60000") |> String.to_integer(),
    proxy_limit: (System.get_env("RATE_LIMIT_PROXY_LIMIT") || "10000") |> String.to_integer(),
    proxy_window_ms:
      (System.get_env("RATE_LIMIT_PROXY_WINDOW_MS") || "60000") |> String.to_integer()
end
