defmodule Plugboard.MountNotifier do
  @moduledoc """
  PostgreSQL LISTEN/NOTIFY listener for mount point and domain affinity changes.

  This GenServer establishes a dedicated PostgreSQL connection to listen for
  changes via notification channels:
  - `plugboard_mounts` - Mount point changes
  - `plugboard_domain_affinities` - Domain affinity changes

  When changes are received, it updates the MountStore ETS tables accordingly.

  ## Connection Recovery

  If the PostgreSQL connection is lost, this module will automatically attempt
  to reconnect with exponential backoff (max 30 seconds between attempts).
  """

  use GenServer
  require Logger

  @mount_channel "plugboard_mounts"
  @domain_channel "plugboard_domain_affinities"
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

      {:error, reason} ->
        Logger.error("MountNotifier: Initial connection failed: #{inspect(reason)}, will retry")
        # Schedule reconnect
        Process.send_after(self(), :reconnect, @initial_backoff)
        {:ok, %{pid: nil, ref: nil, reconnect_attempts: 0}}
    end
  end

  @impl true
  def handle_info({:notification, _pid, _ref, @mount_channel, payload}, state) do
    case Jason.decode(payload) do
      {:ok, %{"action" => action, "full_path" => full_path}} ->
        handle_mount_notification(action, full_path)

      {:error, error} ->
        Logger.error("MountNotifier: Failed to decode mount notification: #{inspect(error)}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:notification, _pid, _ref, @domain_channel, payload}, state) do
    case Jason.decode(payload) do
      {:ok, data} ->
        handle_domain_affinity_notification(data)

      {:error, error} ->
        Logger.error(
          "MountNotifier: Failed to decode domain affinity notification: #{inspect(error)}"
        )
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, %{pid: pid} = state) do
    Logger.error("MountNotifier: PostgreSQL connection died: #{inspect(reason)}")

    # Calculate exponential backoff
    backoff = calculate_backoff(state.reconnect_attempts)
    Logger.info("MountNotifier: Will retry connection in #{backoff}ms")

    Process.send_after(self(), :reconnect, backoff)

    {:noreply, %{state | pid: nil, ref: nil, reconnect_attempts: state.reconnect_attempts + 1}}
  end

  @impl true
  def handle_info(:reconnect, state) do
    case connect() do
      {:ok, new_state} ->
        Logger.info("MountNotifier: Successfully reconnected to PostgreSQL")
        {:noreply, %{new_state | reconnect_attempts: 0}}

      {:error, reason} ->
        Logger.error("MountNotifier: Reconnection failed: #{inspect(reason)}")

        # Try again with backoff
        backoff = calculate_backoff(state.reconnect_attempts)
        Logger.info("MountNotifier: Will retry connection in #{backoff}ms")

        Process.send_after(self(), :reconnect, backoff)

        {:noreply, %{state | reconnect_attempts: state.reconnect_attempts + 1}}
    end
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("MountNotifier: Received unexpected message: #{inspect(msg)}")
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
        Process.monitor(pid)

        # Listen to both channels
        with {:ok, mount_ref} <- Postgrex.Notifications.listen(pid, @mount_channel),
             {:ok, domain_ref} <- Postgrex.Notifications.listen(pid, @domain_channel) do
          Logger.info(
            "MountNotifier: Listening on PostgreSQL channels '#{@mount_channel}' and '#{@domain_channel}'"
          )

          {:ok, %{pid: pid, mount_ref: mount_ref, domain_ref: domain_ref, reconnect_attempts: 0}}
        else
          {:error, reason} ->
            Logger.error("MountNotifier: Failed to listen on channel: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("MountNotifier: Failed to connect to PostgreSQL: #{inspect(reason)}")
        {:error, reason}
    end
  rescue
    e ->
      Logger.error("MountNotifier: Exception during connection: #{inspect(e)}")
      {:error, e}
  end

  defp calculate_backoff(attempts) do
    # Exponential backoff: 1s, 2s, 4s, 8s, 16s, 30s (max)
    backoff = @initial_backoff * :math.pow(2, attempts)
    min(trunc(backoff), @max_backoff)
  end

  defp handle_mount_notification("mount_added", full_path) do
    Logger.debug("MountNotifier: Received mount_added for #{full_path}")
    Plugboard.MountStore.refresh_mount(full_path)
  end

  defp handle_mount_notification("mount_removed", full_path) do
    Logger.debug("MountNotifier: Received mount_removed for #{full_path}")
    Plugboard.MountStore.remove_mount(full_path)
  end

  defp handle_mount_notification(action, full_path) do
    Logger.warning("MountNotifier: Received unknown action '#{action}' for #{full_path}")
  end

  defp handle_domain_affinity_notification(%{
         "action" => "domain_affinity_added",
         "domain" => domain,
         "path_id" => path_id,
         "full_path" => full_path
       }) do
    Logger.debug("MountNotifier: Received domain_affinity_added for #{domain} → #{full_path}")
    Plugboard.MountStore.refresh_domain_affinity(domain, path_id, full_path)
  end

  defp handle_domain_affinity_notification(%{
         "action" => "domain_affinity_removed",
         "domain" => domain
       }) do
    Logger.debug("MountNotifier: Received domain_affinity_removed for #{domain}")
    Plugboard.MountStore.remove_domain_affinity(domain)
  end

  defp handle_domain_affinity_notification(data) do
    Logger.warning(
      "MountNotifier: Received unknown domain affinity notification: #{inspect(data)}"
    )
  end
end
