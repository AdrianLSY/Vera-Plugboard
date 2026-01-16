defmodule Plugboard.HookStore do
  @moduledoc """
  In-memory ETS-based store for hooks with PostgreSQL synchronization.

  This module maintains a fast lookup table of all active hooks per path and provides
  efficient retrieval for incoming proxy requests. It synchronizes with PostgreSQL
  via NOTIFY/LISTEN and handles automatic reconciliation.

  ## Responsibilities
  - Load hooks from database on startup
  - Provide fast O(1) lookups for hooks by path_id
  - Handle incremental updates via PostgreSQL NOTIFY
  - Periodic reconciliation with database

  ## Storage Schema
  ETS table `:plugboard_hooks` stores:
  - Key: `path_id` (binary_id)
  - Value: `[%Hook{}, ...]` (list of hooks ordered by execution_order)
  """

  use GenServer
  require Logger

  alias Plugboard.Repo
  alias Plugboard.Hooks.Hook
  import Ecto.Query

  @table_name :plugboard_hooks

  # Client API

  @doc """
  Starts the HookStore GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns hooks for a path, ordered by execution_order.

  Returns an empty list if no hooks exist for the path.

  ## Examples

      iex> get_hooks(path_id)
      [%Hook{execution_order: 1}, %Hook{execution_order: 2}, ...]

      iex> get_hooks(nonexistent_path_id)
      []
  """
  def get_hooks(path_id) do
    case :ets.lookup(@table_name, path_id) do
      [{^path_id, hooks}] -> hooks
      [] -> []
    end
  end

  @doc """
  Refreshes hooks for a single path in the ETS table.

  Called when receiving NOTIFY updates from PostgreSQL.
  """
  def refresh_hooks(path_id) do
    GenServer.cast(__MODULE__, {:refresh_hooks, path_id})
  end

  @doc """
  Forces a full reload of all hooks from the database.

  Useful for testing and manual reconciliation.
  """
  def reload_all do
    GenServer.call(__MODULE__, :reload_all)
  end

  @doc """
  Returns all hooks currently in the ETS table.

  Primarily for testing and debugging.
  """
  def list_all_hooks do
    :ets.tab2list(@table_name)
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

    Logger.info("HookStore: ETS table created")

    # Load initial data from database
    {_count, _duration} = load_hooks_from_db(:startup)

    # Schedule periodic reconciliation
    schedule_reconciliation()

    {:ok, %{}}
  end

  @impl true
  def handle_cast({:refresh_hooks, path_id}, state) do
    try do
      # Load hooks for this path
      hooks =
        Hook
        |> where([h], h.path_id == ^path_id and is_nil(h.deleted_at))
        |> order_by([h], asc: h.execution_order)
        |> Repo.all()

      if Enum.empty?(hooks) do
        # No hooks for this path - remove from ETS
        :ets.delete(@table_name, path_id)
        Logger.debug("HookStore: Removed hooks for path #{path_id} (none active)")
      else
        # Update ETS with new hooks
        :ets.insert(@table_name, {path_id, hooks})
        Logger.debug("HookStore: Refreshed #{length(hooks)} hooks for path #{path_id}")
      end
    rescue
      e in Postgrex.Error ->
        Logger.error(
          "HookStore: Database error refreshing hooks for path #{path_id}: #{inspect(e.postgres)}"
        )

        :telemetry.execute(
          [:plugboard, :hook_store, :error],
          %{count: 1},
          %{operation: :refresh_hooks, error: :database_error}
        )

      e in DBConnection.ConnectionError ->
        Logger.error("HookStore: Database connection lost during refresh: #{inspect(e)}")

        :telemetry.execute(
          [:plugboard, :hook_store, :error],
          %{count: 1},
          %{operation: :refresh_hooks, error: :connection_error}
        )

      e ->
        Logger.error("HookStore: Unexpected error refreshing hooks: #{inspect(e)}")

        :telemetry.execute(
          [:plugboard, :hook_store, :error],
          %{count: 1},
          %{operation: :refresh_hooks, error: :unknown}
        )
    end

    {:noreply, state}
  end

  @impl true
  def handle_call(:reload_all, _from, state) do
    {count, _duration} = load_hooks_from_db(:manual)
    {:reply, {:ok, count}, state}
  end

  @impl true
  def handle_info(:reconcile, state) do
    Logger.debug("HookStore: Running periodic reconciliation")
    {_count, _duration} = load_hooks_from_db(:periodic)
    schedule_reconciliation()
    {:noreply, state}
  end

  # Private helpers

  defp load_hooks_from_db(trigger) do
    start_time = System.monotonic_time()

    try do
      # Load all active hooks grouped by path_id
      hooks_by_path =
        Hook
        |> where([h], is_nil(h.deleted_at))
        |> order_by([h], asc: h.path_id, asc: h.execution_order)
        |> Repo.all()
        |> Enum.group_by(& &1.path_id)

      # Clear and repopulate ETS table
      :ets.delete_all_objects(@table_name)

      # Insert each path's hooks
      Enum.each(hooks_by_path, fn {path_id, hooks} ->
        :ets.insert(@table_name, {path_id, hooks})
      end)

      total_hooks = hooks_by_path |> Map.values() |> List.flatten() |> length()
      path_count = map_size(hooks_by_path)
      duration = System.monotonic_time() - start_time
      duration_ms = System.convert_time_unit(duration, :native, :millisecond)

      Logger.info(
        "HookStore: Loaded #{total_hooks} hooks for #{path_count} paths from database in #{duration_ms}ms"
      )

      # Emit telemetry
      :telemetry.execute(
        [:plugboard, :hook_store, :reload],
        %{duration: duration_ms, hook_count: total_hooks, path_count: path_count},
        %{trigger: trigger}
      )

      # Also emit a gauge metric for current hook count
      :telemetry.execute(
        [:plugboard, :hook_store, :size],
        %{hook_count: total_hooks, path_count: path_count},
        %{}
      )

      {total_hooks, duration_ms}
    rescue
      e in Postgrex.Error ->
        Logger.error("HookStore: Database error during reload: #{inspect(e.postgres)}")

        :telemetry.execute(
          [:plugboard, :hook_store, :error],
          %{count: 1},
          %{operation: :reload, error: :database_error, trigger: trigger}
        )

        # Return current ETS size instead of crashing
        current_size = :ets.info(@table_name, :size)
        {current_size, 0}

      e in DBConnection.ConnectionError ->
        Logger.error("HookStore: Database connection lost during reload: #{inspect(e)}")

        :telemetry.execute(
          [:plugboard, :hook_store, :error],
          %{count: 1},
          %{operation: :reload, error: :connection_error, trigger: trigger}
        )

        # Return current ETS size instead of crashing
        current_size = :ets.info(@table_name, :size)
        {current_size, 0}

      e ->
        Logger.error("HookStore: Unexpected error during reload: #{inspect(e)}")

        :telemetry.execute(
          [:plugboard, :hook_store, :error],
          %{count: 1},
          %{operation: :reload, error: :unknown, trigger: trigger}
        )

        # Return current ETS size instead of crashing
        current_size = :ets.info(@table_name, :size)
        {current_size, 0}
    end
  end

  defp schedule_reconciliation do
    # Reconcile every 5 minutes (same as MountStore)
    interval = Application.get_env(:plugboard, __MODULE__, [])[:reconcile_interval] || 300_000
    Process.send_after(self(), :reconcile, interval)
  end
end
