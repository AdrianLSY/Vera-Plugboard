defmodule Plugboard.TelephoneRegistry do
  @moduledoc """
  Registry for tracking connected telephone processes.

  Maintains an ETS table mapping path_ids to lists of telephone channel PIDs.
  Implements round-robin load balancing for multiple telephones on the same path.
  """

  use GenServer
  require Logger

  @table_name :telephone_registry

  ## Public API

  @doc """
  Starts the TelephoneRegistry GenServer.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Registers a telephone channel for a given path.

  ## Parameters
    - path_id: The path ID this telephone serves
    - telephone_pid: The PID of the telephone channel process
  """
  def register(path_id, telephone_pid) when is_binary(path_id) and is_pid(telephone_pid) do
    GenServer.call(__MODULE__, {:register, path_id, telephone_pid})
  end

  @doc """
  Unregisters a telephone channel from a path.
  """
  def unregister(path_id, telephone_pid) when is_binary(path_id) and is_pid(telephone_pid) do
    GenServer.call(__MODULE__, {:unregister, path_id, telephone_pid})
  end

  @doc """
  Gets the next available telephone for a path using round-robin.

  Returns {:ok, pid} if a telephone is available, {:error, :no_telephone} otherwise.
  """
  def get_telephone(path_id) when is_binary(path_id) do
    GenServer.call(__MODULE__, {:get_telephone, path_id})
  end

  @doc """
  Lists all telephones registered to a path.
  """
  def list_telephones(path_id) when is_binary(path_id) do
    case :ets.lookup(@table_name, {:telephones, path_id}) do
      [{_, telephones}] -> telephones
      [] -> []
    end
  end

  @doc """
  Counts the number of telephones registered to a path.
  """
  def count_telephones(path_id) when is_binary(path_id) do
    length(list_telephones(path_id))
  end

  @doc """
  Lists all paths that have at least one telephone registered.
  """
  def list_active_paths do
    @table_name
    |> :ets.match({{:telephones, :"$1"}, :_})
    |> List.flatten()
  end

  @doc """
  Gets statistics about the registry.
  """
  def stats do
    paths = list_active_paths()

    total_telephones =
      Enum.reduce(paths, 0, fn path_id, acc ->
        acc + count_telephones(path_id)
      end)

    %{
      active_paths: length(paths),
      total_telephones: total_telephones
    }
  end

  ## GenServer Callbacks

  @impl true
  def init(_opts) do
    # Create ETS table with public read access for efficient lookups
    table =
      :ets.new(@table_name, [
        :set,
        :named_table,
        :public,
        read_concurrency: true
      ])

    Logger.info("TelephoneRegistry started")

    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:register, path_id, telephone_pid}, _from, state) do
    # Monitor the telephone process so we can clean up when it dies
    Process.monitor(telephone_pid)

    # Get current list of telephones for this path
    telephones = list_telephones(path_id)

    # Add the new telephone if not already present
    updated_telephones =
      if telephone_pid in telephones do
        telephones
      else
        telephones ++ [telephone_pid]
      end

    # Update ETS table
    :ets.insert(@table_name, {{:telephones, path_id}, updated_telephones})

    # Initialize counter if it doesn't exist
    unless :ets.member(@table_name, {:counter, path_id}) do
      :ets.insert(@table_name, {{:counter, path_id}, 0})
    end

    # Emit telemetry
    :telemetry.execute(
      [:plugboard, :telephone, :registered],
      %{count: 1},
      %{path_id: path_id, total: length(updated_telephones)}
    )

    Logger.debug("Registered telephone #{inspect(telephone_pid)} for path #{path_id}")

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:unregister, path_id, telephone_pid}, _from, state) do
    # Get current list of telephones
    telephones = list_telephones(path_id)

    # Remove the telephone
    updated_telephones = List.delete(telephones, telephone_pid)

    # Update ETS table
    if updated_telephones == [] do
      # No more telephones for this path, remove entries
      :ets.delete(@table_name, {:telephones, path_id})
      :ets.delete(@table_name, {:counter, path_id})
    else
      :ets.insert(@table_name, {{:telephones, path_id}, updated_telephones})
    end

    # Emit telemetry
    :telemetry.execute(
      [:plugboard, :telephone, :unregistered],
      %{count: 1},
      %{path_id: path_id, remaining: length(updated_telephones)}
    )

    Logger.debug("Unregistered telephone #{inspect(telephone_pid)} from path #{path_id}")

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:get_telephone, path_id}, _from, state) do
    case :ets.lookup(@table_name, {:telephones, path_id}) do
      [{_, telephones}] when telephones != [] ->
        # Get current counter
        counter =
          case :ets.lookup(@table_name, {:counter, path_id}) do
            [{{:counter, ^path_id}, count}] -> count
            [] -> 0
          end

        # Calculate round-robin index
        index = rem(counter, length(telephones))
        telephone_pid = Enum.at(telephones, index)

        # Increment counter for next request
        :ets.update_counter(
          @table_name,
          {:counter, path_id},
          {2, 1},
          {{:counter, path_id}, 0}
        )

        {:reply, {:ok, telephone_pid}, state}

      _ ->
        {:reply, {:error, :no_telephone}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    # A telephone process died, clean it up from all paths
    cleanup_dead_telephone(pid, reason)
    {:noreply, state}
  end

  ## Private Functions

  defp cleanup_dead_telephone(pid, reason) do
    # Find all paths this telephone was registered to
    paths = list_active_paths()

    Enum.each(paths, fn path_id ->
      telephones = list_telephones(path_id)

      if pid in telephones do
        # Remove the dead process
        updated_telephones = List.delete(telephones, pid)

        if updated_telephones == [] do
          :ets.delete(@table_name, {:telephones, path_id})
          :ets.delete(@table_name, {:counter, path_id})
        else
          :ets.insert(@table_name, {{:telephones, path_id}, updated_telephones})
        end

        Logger.info(
          "Cleaned up dead telephone #{inspect(pid)} from path #{path_id}, reason: #{inspect(reason)}"
        )

        # Emit telemetry
        :telemetry.execute(
          [:plugboard, :telephone, :disconnected],
          %{count: 1},
          %{path_id: path_id, reason: reason}
        )
      end
    end)
  end
end
