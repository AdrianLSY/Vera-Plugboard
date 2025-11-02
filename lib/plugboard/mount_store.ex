defmodule Plugboard.MountStore do
  @moduledoc """
  In-memory ETS-based store for mount points with PostgreSQL synchronization.

  This module maintains a fast lookup table of all active mount points and provides
  efficient path matching for incoming proxy requests. It synchronizes with PostgreSQL
  via NOTIFY/LISTEN and handles automatic reconciliation.

  ## Responsibilities
  - Load mount points from database on startup
  - Provide fast O(1) lookups for mount point matching
  - Handle incremental updates via PostgreSQL NOTIFY
  - Periodic reconciliation with database

  ## Storage Schema
  ETS table `:plugboard_mounts` stores:
  - Key: `full_path` (string)
  - Value: `{id, updated_at}` (tuple)
  """

  use GenServer
  require Logger
  alias Plugboard.Repo
  alias Plugboard.Paths.Path
  import Ecto.Query

  @table_name :plugboard_mounts

  # Client API

  @doc """
  Starts the MountStore GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Matches a request path against registered mount points.

  Returns `{:ok, {mount_path, forwarded_path, mount_id}}` if a mount is found,
  or `{:error, :not_found}` if no mount matches.

  Emits telemetry event `[:plugboard, :mount_store, :match]` with:
  - Measurements: `%{duration: native_time}`
  - Metadata: `%{result: :ok | :error, path: request_path}`

  ## Algorithm
  1. Normalize the request path (ensure leading slash, remove trailing slash)
  2. Try exact match against ETS
  3. If not found, strip last segment and retry
  4. Continue until match found or path exhausted

  ## Examples

      iex> MountStore.match("/xyz/todo/items")
      {:ok, {"/xyz", "/todo/items", "mount-id-123"}}

      iex> MountStore.match("/abc/todo/list")
      {:ok, {"/abc/todo", "/list", "mount-id-456"}}

      iex> MountStore.match("/nonexistent")
      {:error, :not_found}
  """
  def match(request_path) do
    start_time = System.monotonic_time()
    normalized_path = normalize_path(request_path)
    result = do_match(normalized_path, normalized_path)
    duration = System.monotonic_time() - start_time

    # Emit telemetry
    :telemetry.execute(
      [:plugboard, :mount_store, :match],
      %{duration: duration},
      %{result: elem(result, 0), path: request_path}
    )

    result
  end

  @doc """
  Refreshes a single mount point in the ETS table.

  Called when receiving NOTIFY updates from PostgreSQL.
  """
  def refresh_mount(full_path) do
    GenServer.cast(__MODULE__, {:refresh_mount, full_path})
  end

  @doc """
  Removes a mount point from the ETS table.

  Called when a mount point is deleted or unmarked.
  """
  def remove_mount(full_path) do
    GenServer.cast(__MODULE__, {:remove_mount, full_path})
  end

  @doc """
  Forces a full reload of all mounts from the database.

  Useful for testing and manual reconciliation.

  Emits telemetry event `[:plugboard, :mount_store, :reload]` with:
  - Measurements: `%{duration: milliseconds, count: mount_count}`
  - Metadata: `%{trigger: :manual | :periodic}`
  """
  def reload_all do
    GenServer.call(__MODULE__, :reload_all)
  end

  @doc """
  Returns all mount points currently in the ETS table.

  Primarily for testing and debugging.
  """
  def list_mounts do
    :ets.tab2list(@table_name)
  end

  # Private matching logic

  defp do_match(_original_path, ""), do: {:error, :not_found}
  defp do_match(_original_path, "/"), do: {:error, :not_found}

  defp do_match(original_path, current_path) do
    case :ets.lookup(@table_name, current_path) do
      [{^current_path, {id, _updated_at}}] ->
        # Found a match - compute forwarded path
        forwarded_path = String.replace_prefix(original_path, current_path, "")

        forwarded_path =
          if forwarded_path == "" do
            "/"
          else
            forwarded_path
          end

        {:ok, {current_path, forwarded_path, id}}

      [] ->
        # No match - strip last segment and retry
        case strip_last_segment(current_path) do
          {:ok, parent_path} -> do_match(original_path, parent_path)
          :error -> {:error, :not_found}
        end
    end
  end

  defp normalize_path(path) do
    path
    |> String.trim()
    # Ensure leading slash
    |> then(fn p -> if String.starts_with?(p, "/"), do: p, else: "/" <> p end)
    # Remove trailing slash (unless it's just "/")
    |> then(fn
      "/" -> "/"
      p -> String.trim_trailing(p, "/")
    end)
  end

  defp strip_last_segment("/"), do: :error

  defp strip_last_segment(path) do
    case String.split(path, "/") |> Enum.reject(&(&1 == "")) do
      [] -> :error
      segments -> {:ok, "/" <> Enum.join(Enum.drop(segments, -1), "/")}
    end
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    # Create ETS table
    :ets.new(@table_name, [
      :named_table,
      :set,
      :protected,
      read_concurrency: true
    ])

    Logger.info("MountStore: ETS table created")

    # Load initial data from database
    {_count, _duration} = load_mounts_from_db(:startup)

    # Schedule periodic reconciliation
    schedule_reconciliation()

    {:ok, %{}}
  end

  @impl true
  def handle_cast({:refresh_mount, full_path}, state) do
    try do
      case Repo.one(
             from p in Path,
               where: p.full_path == ^full_path,
               where: p.mount_point == true,
               where: is_nil(p.deleted_at),
               select: {p.id, p.updated_at}
           ) do
        {id, updated_at} ->
          :ets.insert(@table_name, {full_path, {id, updated_at}})
          Logger.debug("MountStore: Refreshed mount #{full_path}")

        nil ->
          # Mount doesn't exist or is no longer a mount point - remove it
          :ets.delete(@table_name, full_path)
          Logger.debug("MountStore: Removed mount #{full_path}")
      end
    rescue
      e in Postgrex.Error ->
        Logger.error(
          "MountStore: Database error refreshing mount #{full_path}: #{inspect(e.postgres)}"
        )

        :telemetry.execute(
          [:plugboard, :mount_store, :error],
          %{count: 1},
          %{operation: :refresh_mount, error: :database_error}
        )

      e in DBConnection.ConnectionError ->
        Logger.error("MountStore: Database connection lost during refresh: #{inspect(e)}")

        :telemetry.execute(
          [:plugboard, :mount_store, :error],
          %{count: 1},
          %{operation: :refresh_mount, error: :connection_error}
        )

      e ->
        Logger.error("MountStore: Unexpected error refreshing mount #{full_path}: #{inspect(e)}")

        :telemetry.execute(
          [:plugboard, :mount_store, :error],
          %{count: 1},
          %{operation: :refresh_mount, error: :unknown}
        )
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:remove_mount, full_path}, state) do
    :ets.delete(@table_name, full_path)
    Logger.debug("MountStore: Removed mount #{full_path}")
    {:noreply, state}
  end

  @impl true
  def handle_call(:reload_all, _from, state) do
    {count, _duration} = load_mounts_from_db(:manual)
    {:reply, {:ok, count}, state}
  end

  @impl true
  def handle_info(:reconcile, state) do
    Logger.debug("MountStore: Running periodic reconciliation")
    {_count, _duration} = load_mounts_from_db(:periodic)
    schedule_reconciliation()
    {:noreply, state}
  end

  # Private helpers

  defp load_mounts_from_db(trigger) do
    start_time = System.monotonic_time()

    try do
      mounts =
        Repo.all(
          from p in Path,
            where: p.mount_point == true,
            where: is_nil(p.deleted_at),
            select: {p.full_path, {p.id, p.updated_at}}
        )

      # Clear and repopulate ETS table
      :ets.delete_all_objects(@table_name)
      :ets.insert(@table_name, mounts)

      count = length(mounts)
      duration = System.monotonic_time() - start_time
      duration_ms = System.convert_time_unit(duration, :native, :millisecond)

      Logger.info("MountStore: Loaded #{count} mounts from database in #{duration_ms}ms")

      # Emit telemetry
      :telemetry.execute(
        [:plugboard, :mount_store, :reload],
        %{duration: duration_ms, count: count},
        %{trigger: trigger}
      )

      # Also emit a gauge metric for current mount count
      :telemetry.execute(
        [:plugboard, :mount_store, :size],
        %{count: count},
        %{}
      )

      {count, duration_ms}
    rescue
      e in Postgrex.Error ->
        Logger.error("MountStore: Database error during reload: #{inspect(e.postgres)}")

        :telemetry.execute(
          [:plugboard, :mount_store, :error],
          %{count: 1},
          %{operation: :reload, error: :database_error, trigger: trigger}
        )

        # Return current ETS size instead of crashing
        current_size = :ets.info(@table_name, :size)
        {current_size, 0}

      e in DBConnection.ConnectionError ->
        Logger.error("MountStore: Database connection lost during reload: #{inspect(e)}")

        :telemetry.execute(
          [:plugboard, :mount_store, :error],
          %{count: 1},
          %{operation: :reload, error: :connection_error, trigger: trigger}
        )

        # Return current ETS size instead of crashing
        current_size = :ets.info(@table_name, :size)
        {current_size, 0}

      e ->
        Logger.error("MountStore: Unexpected error during reload: #{inspect(e)}")

        :telemetry.execute(
          [:plugboard, :mount_store, :error],
          %{count: 1},
          %{operation: :reload, error: :unknown, trigger: trigger}
        )

        # Return current ETS size instead of crashing
        current_size = :ets.info(@table_name, :size)
        {current_size, 0}
    end
  end

  defp schedule_reconciliation do
    interval = Application.get_env(:plugboard, __MODULE__, [])[:reconcile_interval] || 300_000
    Process.send_after(self(), :reconcile, interval)
  end
end
