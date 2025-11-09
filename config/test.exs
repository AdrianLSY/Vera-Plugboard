import Config

# Only in tests, remove the complexity from the password hashing algorithm
config :argon2_elixir, t_cost: 1, m_cost: 8

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :plugboard, Plugboard.Repo,
  username: System.get_env("POSTGRES_USER"),
  password: System.get_env("POSTGRES_PASSWORD"),
  hostname: System.get_env("POSTGRES_HOST"),
  port: String.to_integer(System.get_env("POSTGRES_PORT")),
  database: "#{System.get_env("POSTGRES_DB")}_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2,
  # Query and connection timeouts
  timeout: 15_000,
  connect_timeout: 5_000

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :plugboard, PlugboardWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base:
    "test_secret_key_base_that_is_at_least_64_bytes_long_for_testing_jwt_tokens_securely",
  server: false

# In test we don't send emails
config :plugboard, Plugboard.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only errors during test (suppress warnings from security tests)
config :logger, level: :error

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# MountStore configuration - use shorter interval for tests (30 seconds)
# Override with MOUNT_STORE_RECONCILE_INTERVAL env var
config :plugboard, Plugboard.MountStore,
  reconcile_interval: System.get_env("MOUNT_STORE_RECONCILE_INTERVAL") |> String.to_integer()

# Request body size limit (in bytes)
# Fails fast if MAX_REQUEST_BODY_SIZE environment variable is not set
config :plugboard,
       :max_request_body_length,
       System.fetch_env!("MAX_REQUEST_BODY_SIZE") |> String.to_integer()
