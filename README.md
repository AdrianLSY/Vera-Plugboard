# Vera

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
To run or develop with the Phoenix web server, you'll need to configure the following environment variables:

```env
PHX_POSTGRES_USERNAME=vera
PHX_POSTGRES_PASSWORD=vera
PHX_POSTGRES_DATABASE=vera
SECRET_KEY_BASE=d7B/S11o4a4BHuSRjF+CGnokmZrC+7nN/HEEjC3XT9ZfSf2OHLzg8HfJN2UeyknXwNLxGtMND0SIb5ez3aM6wA==
PHX_POOL_SIZE=10
PHX_HOST=example.com
PHX_PORT=4000
PHX_DEVELOPMENT_DATABASE_URL=ecto://vera:vera@localhost/vera_development
PHX_TEST_DATABASE_URL=ecto://vera:vera@localhost/vera_test
PHX_PRODUCTION_DATABASE_URL=ecto://vera:vera@localhost/vera_production
```

## Running the server

To start the server, run the following command:

```bash
source .env && mix phx.server
```

This will start the server on port 4000.
