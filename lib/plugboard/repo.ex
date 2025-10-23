defmodule Plugboard.Repo do
  use Ecto.Repo,
    otp_app: :plugboard,
    adapter: Ecto.Adapters.Postgres
end
