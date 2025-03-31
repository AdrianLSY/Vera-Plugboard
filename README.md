# Vera Pugboard

To start the Phoenix server:

  * Run `mix setup` to install and setup dependencies
  * Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

Ready to run in production? Please [check our deployment guides](https://hexdocs.pm/phoenix/deployment.html).

## Learn more

  * Official website: https://www.phoenixframework.org/
  * Guides: https://hexdocs.pm/phoenix/overview.html
  * Docs: https://hexdocs.pm/phoenix
  * Forum: https://elixirforum.com/c/phoenix-forum
  * Source: https://github.com/phoenixframework/phoenix


## Environment Configuration
To run the Phoenix server, you'll need to add and configure the following environment variables:

```env
SECRET_KEY_BASE={generate a secret key base via `elixir -e "IO.puts(:crypto.strong_rand_bytes(64) |> Base.encode64())"`}
PHX_HOST=localhost
PHX_PORT=4000
PHX_POOL_SIZE=10
PHX_DEVELOPMENT_DATABASE_URL=ecto://vera:vera@localhost/vera_development
PHX_TEST_DATABASE_URL=ecto://vera:vera@localhost/vera_test
PHX_PRODUCTION_DATABASE_URL=ecto://vera:vera@postgres/vera_production
PHX_POSTGRES_USERNAME=vera
PHX_POSTGRES_PASSWORD=vera
PHX_POSTGRES_DATABASE=vera
PHX_POSTGRES_PORT=5432
```
This will serve as a starting point for your own environment variables. Feel free to change the values to suit your needs.

## Running the server

To start the server, run the following command:

```bash
mix phx.server
```

This will start the server.
