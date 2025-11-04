defmodule Plugboard.TelephoneTokens.TokenCleanup do
  @moduledoc """
  GenServer that periodically cleans up expired telephone tokens.

  Runs cleanup every hour to remove expired tokens from the database.
  This prevents unbounded growth of the telephone_tokens table.
  """

  use GenServer
  require Logger

  alias Plugboard.TelephoneTokens

  @cleanup_interval :timer.hours(1)

  ## Public API

  @doc """
  Starts the token cleanup GenServer.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Manually triggers a cleanup (useful for testing).
  """
  def cleanup_now do
    GenServer.call(__MODULE__, :cleanup_now)
  end

  ## GenServer Callbacks

  @impl true
  def init(_opts) do
    # Schedule first cleanup
    schedule_cleanup()

    Logger.info("TokenCleanup started, will run every #{@cleanup_interval / 1000 / 60} minutes")

    {:ok, %{}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    # Run cleanup
    {:ok, count} = TelephoneTokens.delete_expired_tokens()

    if count > 0 do
      Logger.info("TokenCleanup: Removed #{count} expired tokens")
    end

    # Schedule next cleanup
    schedule_cleanup()

    {:noreply, state}
  end

  @impl true
  def handle_call(:cleanup_now, _from, state) do
    result = TelephoneTokens.delete_expired_tokens()
    {:reply, result, state}
  end

  ## Private Functions

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end
end
