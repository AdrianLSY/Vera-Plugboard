defmodule Vera.Repo do
  use Ecto.Repo,
    otp_app: :vera,
    adapter: Ecto.Adapters.Postgres
end
