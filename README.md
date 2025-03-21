# Vera

To start your Phoenix server:

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
To run the Phoenix server, you'll need to configure the following environment variables. Create a `.env` file in the project root directory with these settings:

```env
export DEVELOPMENT_DATABASE_URL=ecto://vera:vera@localhost/vera_development
export TEST_DATABASE_URL=ecto://vera:vera@localhost/vera_test
export PRODUCTION_DATABASE_URL=ecto://vera:vera@localhost/vera_production
```

## Running the server

To start the server, run the following command:

```bash
source .env && mix phx.server
```

This will start the server on port 4000.
