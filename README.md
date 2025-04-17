# Vera Plugboard

The Plugboard is a web application that allows you to create, define and manage data processing / microservices. It is built using the Phoenix framework. The application is designed to be used with the Vera Services Application which serves as the backend for the application. Together, the plugboard acts as a frontend proxy for the Vera Services Application.

The Plugboard Application has several features:
* Create, edit and delete data processing pipelines / microservices (Which we call "Service")
* Handles service discovery and service registration
* Manages data flows between services

## Learn more

  * Official website: https://www.phoenixframework.org/
  * Guides: https://hexdocs.pm/phoenix/overview.html
  * Docs: https://hexdocs.pm/phoenix
  * Forum: https://elixirforum.com/c/phoenix-forum
  * Source: https://github.com/phoenixframework/phoenix

## Development Environment Configuration
The Phoenix application makes use of several environment variables to run, you'll need to add and configure the following environment variables:

```env
SECRET_KEY_BASE={ Generate one via: mix phx.gen.secret }
PHX_SIGNING_SALT={ Generate one via: mix phx.gen.secret }
PHX_ENCRYPTION_SALT={ Generate one via: mix phx.gen.secret }
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
PHX_GENSTAGE_ENTITY_MAX_AGE=30000
PHX_GENSTAGE_CLEANUP_INTERVAL=1000
PHX_API_TOKEN_VALIDITY_IN_DAYS=365
PHX_RESET_PASSWORD_VALIDITY_IN_DAYS=1
PHX_CONFIRM_VALIDITY_IN_DAYS=1
PHX_CHANGE_EMAIL_VALIDITY_IN_DAYS=1
PHX_SESSION_VALIDITY_IN_DAYS=1
```
This will serve as a starting point for your own environment variables. Feel free to change the values to suit your needs.

## Running the server1

You will need to install elixir before you can run the server. Please follow the instructions on the official elixir
website to install:

* https://elixir-lang.org/install.html

The application is built using
* Elixir 1.18.3 (Compiled with Erlang/OTP 27)

Once elixir is installed, you will need to setup the app and its dependencies before you can run the server. To do this, run the following command:

```bash
mix setup
```

Next, You will need to set up the postgres database. There is already a docker-compose file in the root of the project with the postgres database already configured. You can use this to run the postgres database. Alternatively, you can point to your own postgres database by setting the environment variables:

```bash
docker compose up -d --build 'postgres'
```

Once the postgres database container is running, you will need to create the necessary database. You can do this by running the following command:

```bash
mix ecto.drop && mix ecto.create
```

Make sure to run any pending migrations:

```bash
mix ecto.migrate
```

To start the server, run the following command:

```bash
mix phx.server
```
