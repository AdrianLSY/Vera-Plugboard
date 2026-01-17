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
  - Domain affinity matching (domain → mount point)

  ## Storage Schema
  ETS table `:plugboard_mounts` stores:
  - Key: `full_path` (string)
  - Value: `{id, updated_at}` (tuple)

  ETS table `:plugboard_domain_affinities` stores:
  - Key: `domain` (string)
  - Value: `{path_id, full_path}` (tuple)
  """

  use GenServer
  require Logger

  import Ecto.Query

  alias Plugboard.DomainAffinities
  alias Plugboard.DomainAffinities.DomainAffinity
  alias Plugboard.Paths.Path
  alias Plugboard.Repo

  @table_name :plugboard_mounts
  @domain_table :plugboard_domain_affinities

  # Type definitions
  @type mount_id :: String.t()
  @type full_path :: String.t()
  @type forwarded_path :: String.t()
  @type domain :: String.t()
  @type path_id :: String.t()
  @type match_result :: {:ok, {full_path(), forwarded_path(), mount_id()}} | {:error, :not_found}
  @type domain_match_result :: {:ok, {path_id(), full_path()}} | {:error, :not_found}

  # Client API

  @doc """
  Starts the MountStore GenServer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
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
  @spec match(String.t()) :: match_result()
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
  @spec refresh_mount(String.t()) :: :ok
  def refresh_mount(full_path) do
    GenServer.cast(__MODULE__, {:refresh_mount, full_path})
  end

  @doc """
  Removes a mount point from the ETS table.

  Called when a mount point is deleted or unmarked.
  """
  @spec remove_mount(String.t()) :: :ok
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
  @spec reload_all() :: {:ok, non_neg_integer(), non_neg_integer()}
  def reload_all do
    GenServer.call(__MODULE__, :reload_all)
  end

  @doc """
  Returns all mount points currently in the ETS table.

  Primarily for testing and debugging.
  """
  @spec list_mounts() :: [{String.t(), {String.t(), DateTime.t()}}]
  def list_mounts do
    :ets.tab2list(@table_name)
  end

  @doc """
  Matches a domain against registered domain affinities.

  Returns `{:ok, {path_id, full_path}}` if a domain affinity is found,
  or `{:error, :not_found}` if no match exists.

  ## Matching Strategy
  1. Normalize the domain (lowercase, strip port)
  2. Try exact match in ETS
  3. If not found, try wildcard matches (e.g., `*.example.com`)
  4. Return first match or `:not_found`

  ## Examples

      iex> MountStore.match_by_domain("users.example.com")
      {:ok, {"mount-id-123", "/call/users"}}

      iex> MountStore.match_by_domain("foo.api.example.com")
      {:ok, {"mount-id-456", "/call/api"}}  # Matched *.api.example.com

      iex> MountStore.match_by_domain("unknown.com")
      {:error, :not_found}
  """
  @spec match_by_domain(String.t()) :: domain_match_result()
  def match_by_domain(domain) do
    normalized = DomainAffinities.normalize_domain(domain)

    # Try exact match first
    case :ets.lookup(@domain_table, normalized) do
      [{^normalized, {path_id, full_path}}] ->
        {:ok, {path_id, full_path}}

      [] ->
        # Try wildcard match
        match_wildcard_domain(normalized)
    end
  end

  @doc """
  Refreshes a domain affinity in the ETS table.

  Called when receiving NOTIFY updates from PostgreSQL.
  """
  @spec refresh_domain_affinity(String.t(), String.t(), String.t()) :: :ok
  def refresh_domain_affinity(domain, path_id, full_path) do
    GenServer.cast(__MODULE__, {:refresh_domain_affinity, domain, path_id, full_path})
  end

  @doc """
  Removes a domain affinity from the ETS table.

  Called when a domain affinity is deleted.
  """
  @spec remove_domain_affinity(String.t()) :: :ok
  def remove_domain_affinity(domain) do
    GenServer.cast(__MODULE__, {:remove_domain_affinity, domain})
  end

  @doc """
  Returns all domain affinities currently in the ETS table.

  Primarily for testing and debugging.
  """
  @spec list_domain_affinities() :: [{String.t(), {String.t(), String.t()}}]
  def list_domain_affinities do
    :ets.tab2list(@domain_table)
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

  # Match wildcard domains (e.g., *.example.com)
  defp match_wildcard_domain(domain) do
    # Generate wildcard candidates: foo.bar.example.com → [*.bar.example.com, *.example.com]
    wildcards = generate_wildcard_candidates(domain)

    # Try each wildcard in order (most specific first)
    Enum.find_value(wildcards, {:error, :not_found}, fn wildcard ->
      case :ets.lookup(@domain_table, wildcard) do
        [{^wildcard, {path_id, full_path}}] -> {:ok, {path_id, full_path}}
        [] -> nil
      end
    end)
  end

  defp generate_wildcard_candidates(domain) do
    parts = String.split(domain, ".")

    # For "foo.bar.example.com", generate:
    # ["*.bar.example.com", "*.example.com"]
    parts
    |> Enum.drop(1)
    |> Enum.scan([], fn part, acc -> acc ++ [part] end)
    |> Enum.map(fn parts -> "*." <> Enum.join(parts, ".") end)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    # Create ETS tables
    :ets.new(@table_name, [
      :named_table,
      :set,
      :protected,
      read_concurrency: true
    ])

    :ets.new(@domain_table, [
      :named_table,
      :set,
      :protected,
      read_concurrency: true
    ])

    Logger.info("MountStore: ETS tables created")

    # Use handle_continue to defer database loading
    # This prevents blocking the supervisor during startup
    {:ok, %{}, {:continue, :load_initial_data}}
  end

  @impl true
  def handle_continue(:load_initial_data, state) do
    # Load initial data from database (non-blocking)
    {_count, _duration} = load_mounts_from_db(:startup)
    {_domain_count, _domain_duration} = load_domain_affinities_from_db(:startup)

    # Schedule periodic reconciliation
    schedule_reconciliation()

    {:noreply, state}
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
  def handle_cast({:refresh_domain_affinity, domain, path_id, full_path}, state) do
    :ets.insert(@domain_table, {domain, {path_id, full_path}})
    Logger.debug("MountStore: Refreshed domain affinity #{domain} → #{full_path}")
    {:noreply, state}
  end

  @impl true
  def handle_cast({:remove_domain_affinity, domain}, state) do
    :ets.delete(@domain_table, domain)
    Logger.debug("MountStore: Removed domain affinity #{domain}")
    {:noreply, state}
  end

  @impl true
  def handle_call(:reload_all, _from, state) do
    {count, _duration} = load_mounts_from_db(:manual)
    {domain_count, _domain_duration} = load_domain_affinities_from_db(:manual)
    {:reply, {:ok, count, domain_count}, state}
  end

  @impl true
  def handle_info(:reconcile, state) do
    Logger.debug("MountStore: Running periodic reconciliation")
    {_count, _duration} = load_mounts_from_db(:periodic)
    {_domain_count, _domain_duration} = load_domain_affinities_from_db(:periodic)
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

      # Atomic update: insert new data first, then remove stale entries
      # This avoids the race condition where the table is briefly empty
      new_keys = MapSet.new(mounts, fn {full_path, _value} -> full_path end)

      # Insert all new/updated mounts (ETS insert is upsert for :set tables)
      :ets.insert(@table_name, mounts)

      # Get all current keys and remove those not in the new dataset
      current_keys =
        :ets.select(@table_name, [{{:"$1", :_}, [], [:"$1"]}])
        |> MapSet.new()

      stale_keys = MapSet.difference(current_keys, new_keys)

      Enum.each(stale_keys, fn key ->
        :ets.delete(@table_name, key)
      end)

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
    base_interval =
      Application.get_env(:plugboard, __MODULE__, [])[:reconcile_interval] || 300_000

    # Add 0-10% jitter to prevent thundering herd across cluster nodes
    jitter = :rand.uniform(div(base_interval, 10))
    Process.send_after(self(), :reconcile, base_interval + jitter)
  end

  defp load_domain_affinities_from_db(trigger) do
    start_time = System.monotonic_time()

    try do
      # Load domain affinities with path information using Ecto query
      # This avoids connection lifecycle issues that can occur with raw SQL
      #
      # Note: Ecto returns binary_id as raw binary in select queries, so we
      # convert them to string UUIDs using Ecto.UUID.cast!/1 for consistency
      # with other parts of the codebase.
      domain_affinities =
        from(da in DomainAffinity,
          join: p in Path,
          on: da.path_id == p.id,
          where: is_nil(da.deleted_at) and is_nil(p.deleted_at) and p.mount_point == true,
          select: {da.domain, da.path_id, p.full_path}
        )
        |> Repo.all()
        |> Enum.map(fn {domain, path_id, full_path} ->
          # Convert binary UUID to string format
          path_id_string = Ecto.UUID.cast!(path_id)
          {domain, {path_id_string, full_path}}
        end)

      # Atomic update: insert new data first, then remove stale entries
      # This avoids the race condition where the table is briefly empty
      new_keys = MapSet.new(domain_affinities, fn {domain, _value} -> domain end)

      # Insert all new/updated domain affinities (ETS insert is upsert for :set tables)
      :ets.insert(@domain_table, domain_affinities)

      # Get all current keys and remove those not in the new dataset
      current_keys =
        :ets.select(@domain_table, [{{:"$1", :_}, [], [:"$1"]}])
        |> MapSet.new()

      stale_keys = MapSet.difference(current_keys, new_keys)

      Enum.each(stale_keys, fn key ->
        :ets.delete(@domain_table, key)
      end)

      count = length(domain_affinities)
      duration = System.monotonic_time() - start_time
      duration_ms = System.convert_time_unit(duration, :native, :millisecond)

      Logger.info(
        "MountStore: Loaded #{count} domain affinities from database in #{duration_ms}ms"
      )

      # Emit telemetry
      :telemetry.execute(
        [:plugboard, :mount_store, :domain_affinity_reload],
        %{duration: duration_ms, count: count},
        %{trigger: trigger}
      )

      {count, duration_ms}
    rescue
      e in Postgrex.Error ->
        Logger.error(
          "MountStore: Database error loading domain affinities: #{inspect(e.postgres)}"
        )

        :telemetry.execute(
          [:plugboard, :mount_store, :error],
          %{count: 1},
          %{operation: :load_domain_affinities, error: :database_error, trigger: trigger}
        )

        current_size = :ets.info(@domain_table, :size)
        {current_size, 0}

      e in DBConnection.ConnectionError ->
        Logger.error(
          "MountStore: Database connection lost loading domain affinities: #{inspect(e)}"
        )

        :telemetry.execute(
          [:plugboard, :mount_store, :error],
          %{count: 1},
          %{operation: :load_domain_affinities, error: :connection_error, trigger: trigger}
        )

        current_size = :ets.info(@domain_table, :size)
        {current_size, 0}

      e ->
        Logger.error("MountStore: Unexpected error loading domain affinities: #{inspect(e)}")

        :telemetry.execute(
          [:plugboard, :mount_store, :error],
          %{count: 1},
          %{operation: :load_domain_affinities, error: :unknown, trigger: trigger}
        )

        current_size = :ets.info(@domain_table, :size)
        {current_size, 0}
    end
  end
end
