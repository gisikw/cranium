defmodule Cranium.Macro.Registry do
  @moduledoc """
  In-memory registry of macro definitions, backed by ETS.

  Scans a directory tree for JSON macro definition files at boot,
  parses and indexes them by name. Supports hot-reload via file
  watcher or manual `reload/0`.

  Follows the Config pattern: ETS for lock-free public reads,
  GenServer for serialized load/reload operations.
  """

  use GenServer
  require Logger

  alias Cranium.Macro.Definition

  @table __MODULE__

  # --- Public API (ETS reads — no GenServer.call) ---

  @doc "Look up a macro definition by name."
  @spec get(String.t()) :: {:ok, Definition.t()} | :error
  def get(name) do
    case :ets.lookup(@table, {:macro, name}) do
      [{_, definition}] -> {:ok, definition}
      [] -> :error
    end
  end

  @doc "List all loaded macro definitions."
  @spec list() :: [Definition.t()]
  def list do
    :ets.match_object(@table, {{:macro, :_}, :_})
    |> Enum.map(fn {_key, definition} -> definition end)
    |> Enum.sort_by(& &1.name)
  end

  @doc "List macros with a specific trigger type."
  @spec list_by_trigger(Definition.trigger()) :: [Definition.t()]
  def list_by_trigger(trigger) do
    case :ets.lookup(@table, {:trigger_index, trigger}) do
      [{_, names}] ->
        Enum.flat_map(names, fn name ->
          case get(name) do
            {:ok, def} -> [def]
            :error -> []
          end
        end)

      [] ->
        []
    end
  end

  @doc "List macros with a specific advertising mode."
  @spec list_by_advertising(Definition.advertising()) :: [Definition.t()]
  def list_by_advertising(advertising) do
    case :ets.lookup(@table, {:advertising_index, advertising}) do
      [{_, names}] ->
        Enum.flat_map(names, fn name ->
          case get(name) do
            {:ok, def} -> [def]
            :error -> []
          end
        end)

      [] ->
        []
    end
  end

  @doc "Substring search across name, description, and tags."
  @spec search(String.t()) :: [Definition.t()]
  def search(query) when is_binary(query) do
    downcased = String.downcase(query)

    list()
    |> Enum.filter(fn definition ->
      String.contains?(String.downcase(definition.name), downcased) ||
        String.contains?(String.downcase(definition.description), downcased) ||
        Enum.any?(definition.tags, &String.contains?(String.downcase(&1), downcased))
    end)
  end

  @doc "Return the count of loaded macros."
  @spec count() :: non_neg_integer()
  def count do
    case :ets.lookup(@table, :count) do
      [{_, n}] -> n
      [] -> 0
    end
  end

  @doc "Trigger a reload from disk."
  @spec reload() :: :ok | {:error, term()}
  def reload do
    GenServer.call(__MODULE__, :reload, 30_000)
  end

  # --- GenServer ---

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    path = Keyword.get(opts, :path) || macros_path()

    if path do
      load_from_directory!(path)
      maybe_start_watcher(path)
    else
      Logger.info("Macro.Registry: no macros_path configured, starting empty")
      :ets.insert(@table, {:count, 0})
    end

    {:ok, %{path: path, table: table, watcher_pid: nil}}
  end

  @impl true
  def handle_call(:reload, _from, %{path: path} = state) do
    if path do
      load_from_directory!(path)
      {:reply, :ok, state}
    else
      {:reply, {:error, :no_path}, state}
    end
  end

  @impl true
  def handle_info({:file_event, _watcher_pid, {_path, _events}}, %{path: path} = state) do
    Logger.info("Macro.Registry: file change detected, reloading")
    load_from_directory!(path)
    {:noreply, state}
  end

  def handle_info({:file_event, _watcher_pid, :stop}, state) do
    Logger.warning("Macro.Registry: file watcher stopped")
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Loading ---

  defp load_from_directory!(path) do
    if File.dir?(path) do
      json_files =
        Path.wildcard(Path.join(path, "**/*.json"))
        |> Enum.sort_by(&File.stat!(&1).mtime)

      # Clear existing macros (but not the table itself)
      :ets.match_delete(@table, {{:macro, :_}, :_})

      {loaded, errors} =
        Enum.reduce(json_files, {0, 0}, fn file, {ok, err} ->
          case load_file(file) do
            {:ok, name} ->
              Logger.debug("Macro.Registry: loaded #{name} from #{file}")
              {ok + 1, err}

            {:error, reason} ->
              Logger.warning("Macro.Registry: skipping #{file}: #{reason}")
              {ok, err + 1}
          end
        end)

      rebuild_indices()

      # Count unique macros in ETS (not files loaded — name collisions dedupe)
      unique_count = :ets.match(@table, {{:macro, :_}, :_}) |> length()
      :ets.insert(@table, {:count, unique_count})

      Logger.info("Macro.Registry: loaded #{unique_count} macros from #{loaded} files (#{errors} errors) in #{path}")
    else
      Logger.warning("Macro.Registry: macros_path does not exist: #{path}")
      :ets.insert(@table, {:count, 0})
      rebuild_empty_indices()
    end
  end

  defp load_file(file) do
    with {:ok, content} <- File.read(file),
         {:ok, json} <- Jason.decode(content),
         {:ok, definition} <- Definition.parse(json) do
      definition = %{definition | source_path: file}
      :ets.insert(@table, {{:macro, definition.name}, definition})
      {:ok, definition.name}
    else
      {:error, %Jason.DecodeError{} = err} ->
        {:error, "invalid JSON: #{Exception.message(err)}"}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp rebuild_indices do
    macros = list()

    # Index by trigger type
    trigger_groups = Enum.group_by(macros, & &1.trigger)

    for trigger <- [:explicit, :match, :ambient, :passive] do
      names = trigger_groups |> Map.get(trigger, []) |> Enum.map(& &1.name)
      :ets.insert(@table, {{:trigger_index, trigger}, names})
    end

    # Index by advertising mode
    ad_groups = Enum.group_by(macros, & &1.advertising)

    for advertising <- [:listed, :discoverable, :searchable, :hidden] do
      names = ad_groups |> Map.get(advertising, []) |> Enum.map(& &1.name)
      :ets.insert(@table, {{:advertising_index, advertising}, names})
    end
  end

  defp rebuild_empty_indices do
    for trigger <- [:explicit, :match, :ambient, :passive] do
      :ets.insert(@table, {{:trigger_index, trigger}, []})
    end

    for advertising <- [:listed, :discoverable, :searchable, :hidden] do
      :ets.insert(@table, {{:advertising_index, advertising}, []})
    end
  end

  defp maybe_start_watcher(path) do
    if Code.ensure_loaded?(FileSystem) do
      # Trap exits temporarily so a failed FileSystem.start_link
      # doesn't kill the registry via the link
      prev_trap = Process.flag(:trap_exit, true)

      result =
        try do
          FileSystem.start_link(dirs: [path])
        catch
          :exit, reason -> {:error, reason}
        end

      case result do
        {:ok, pid} ->
          FileSystem.subscribe(pid)
          Logger.info("Macro.Registry: watching #{path} for changes")

        other ->
          # Drain any EXIT message from the failed process
          receive do
            {:EXIT, _pid, _reason} -> :ok
          after
            0 -> :ok
          end

          Logger.warning("Macro.Registry: file watcher failed to start: #{inspect(other)}")
      end

      Process.flag(:trap_exit, prev_trap)
    else
      Logger.info("Macro.Registry: file_system not available, hot reload disabled")
    end
  end

  defp macros_path do
    case Application.get_env(:cranium, :paths) do
      paths when is_list(paths) -> Keyword.get(paths, :macros)
      _ -> nil
    end
  end

end
