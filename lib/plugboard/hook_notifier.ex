defmodule Plugboard.HookNotifier do
  @moduledoc """
  PostgreSQL LISTEN/NOTIFY listener for hook changes.

  This GenServer establishes a dedicated PostgreSQL connection to listen for
  changes via the `plugboard_hooks` notification channel.

  When changes are received, it updates the HookStore ETS table accordingly.

  ## Connection Recovery

  If the PostgreSQL connection is lost, this module will automatically attempt
  to reconnect with exponential backoff (max 30 seconds between attempts).
  """

  use GenServer

  @channel "plugboard_hooks"
  @max_backoff 30_000
  @initial_backoff 1_000

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    # Attempt initial connection
    case connect() do
      {:ok, state} ->
        {:ok, state}

      {:error, _reason} ->
        # Schedule reconnect
        Process.send_after(self(), :reconnect, @initial_backoff)
        {:ok, %{pid: nil, ref: nil, reconnect_attempts: 0}}
    end
  end

  @impl true
  def handle_info({:notification, _pid, _ref, @channel, payload}, state) do
    case Jason.decode(payload) do
      {:ok, %{"action" => action, "path_id" => path_id}} ->
        handle_hook_notification(action, path_id)

      {:error, _error} ->
        :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{pid: pid} = state) do
    # Calculate exponential backoff
    backoff = calculate_backoff(state.reconnect_attempts)

    Process.send_after(self(), :reconnect, backoff)

    {:noreply, %{state | pid: nil, ref: nil, reconnect_attempts: state.reconnect_attempts + 1}}
  end

  @impl true
  def handle_info(:reconnect, state) do
    case connect() do
      {:ok, new_state} ->
        {:noreply, %{new_state | reconnect_attempts: 0}}

      {:error, _reason} ->
        # Try again with backoff
        backoff = calculate_backoff(state.reconnect_attempts)

        Process.send_after(self(), :reconnect, backoff)

        {:noreply, %{state | reconnect_attempts: state.reconnect_attempts + 1}}
    end
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Private helpers

  defp connect do
    # Get database configuration
    repo_config = Plugboard.Repo.config()

    db_config = [
      hostname: repo_config[:hostname] || "localhost",
      port: repo_config[:port] || 5432,
      database: repo_config[:database] || raise("Database not configured"),
      username: repo_config[:username] || System.get_env("USER"),
      password: repo_config[:password],
      socket_options: repo_config[:socket_options] || []
    ]

    # Start Postgrex.Notifications connection
    case Postgrex.Notifications.start_link(db_config) do
      {:ok, pid} ->
        # Monitor the connection so we get notified if it dies
        _ref = Process.monitor(pid)

        # Listen to the channel
        case Postgrex.Notifications.listen(pid, @channel) do
          {:ok, listen_ref} ->
            {:ok, %{pid: pid, ref: listen_ref, reconnect_attempts: 0}}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e ->
      {:error, e}
  end

  defp calculate_backoff(attempts) do
    # Exponential backoff: 1s, 2s, 4s, 8s, 16s, 30s (max)
    backoff = @initial_backoff * :math.pow(2, attempts)
    min(trunc(backoff), @max_backoff)
  end

  defp handle_hook_notification("hook_updated", path_id) do
    Plugboard.HookStore.refresh_hooks(path_id)
  end

  defp handle_hook_notification("hook_deleted", path_id) do
    Plugboard.HookStore.refresh_hooks(path_id)
  end

  defp handle_hook_notification(_action, _path_id) do
    :ok
  end
end
