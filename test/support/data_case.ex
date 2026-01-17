defmodule Plugboard.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use Plugboard.DataCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox
  alias Plugboard.HookNotifier
  alias Plugboard.HookStore
  alias Plugboard.MountNotifier
  alias Plugboard.MountStore
  alias Plugboard.Repo

  using do
    quote do
      alias Plugboard.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Plugboard.DataCase
    end
  end

  setup tags do
    Plugboard.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.
  """
  def setup_sandbox(tags) do
    pid = Sandbox.start_owner!(Repo, shared: not tags[:async])

    # Allow the MountStore GenServer to access the database
    # This is needed because MountStore loads mounts from the DB
    if Process.whereis(MountStore) do
      Sandbox.allow(Repo, pid, MountStore)
    end

    # Allow the MountNotifier GenServer to access the database if it exists
    if Process.whereis(MountNotifier) do
      Sandbox.allow(Repo, pid, MountNotifier)
    end

    # Allow the HookStore GenServer to access the database
    if Process.whereis(HookStore) do
      Sandbox.allow(Repo, pid, HookStore)
    end

    # Allow the HookNotifier GenServer to access the database
    if Process.whereis(HookNotifier) do
      Sandbox.allow(Repo, pid, HookNotifier)
    end

    on_exit(fn -> Sandbox.stop_owner(pid) end)
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
