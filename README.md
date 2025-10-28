# Plugboard

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

## Required Environment Variables

These are the required environment variables for running Plugboard:
```
SECRET_KEY_BASE= {generate one via `mix phx.gen.secret` after running `mix setup`}
PHX_SERVER=true
PHX_PORT=4000
PHX_HOST=localhost

POSTGRES_USER=plugboard
POSTGRES_PASSWORD=plugboard
POSTGRES_DB=plugboard
POSTGRES_HOST=localhost
POSTGRES_PORT=5432
DB_POOL_SIZE=10
```
