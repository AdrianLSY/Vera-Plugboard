# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Inside the script, you can read and write to any of your
# repositories directly:
#
#     Plugboard.Repo.insert!(%Plugboard.SomeSchema{})
#
# We recommend using the bang functions (`insert!`, `update!`
# and so on) as they will fail if something goes wrong.

# Create a default admin account if it doesn't exist
alias Plugboard.Accounts.Accounts
alias Plugboard.Accounts.Account
alias Plugboard.Repo

# Configuration for the default admin
admin_email = System.get_env("PHX_ADMIN_EMAIL")
admin_password = System.get_env("PHX_ADMIN_PASSWORD")

# Check if admin already exists
case Repo.get_by(Account, email: admin_email) do
  nil ->
    # Create admin account
    %Account{}
    |> Account.registration_changeset(%{
      email: admin_email,
      password: admin_password,
      role: :admin
    })
    |> Repo.insert!()

    # Confirm the admin account
    Accounts.get_account_by_email(admin_email)
    |> Account.confirm_changeset()
    |> Repo.update!()

    IO.puts("Admin account created: #{admin_email}")

  _account ->
    IO.puts("Admin account already exists: #{admin_email}")
end
