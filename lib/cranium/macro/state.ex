defmodule Cranium.Macro.State do
  @moduledoc """
  Per-room, per-macro state storage.

  Two tiers of state:

  - **Persistent state** (epoch/condition-scoped): JSON files at
    `{macros_state_path}/{room_name}/{macro_name}.json`. Atomic writes
    via tmp+rename. Survives session restarts.

  - **Session state** (seen-sets, discovered macros): ETS table, not
    persisted to disk. Lost on BEAM restart, which is correct — session
    state is ephemeral by design.
  """

  use GenServer
  require Logger

  @table __MODULE__
  @session_table :"#{__MODULE__}.Session"

  # --- Public API: Persistent state ---

  @doc "Initialize persistent state for a macro in a room from schema defaults."
  @spec init_state(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def init_state(macro_name, room_name, defaults \\ %{}) do
    case get_state(macro_name, room_name) do
      {:ok, _existing} ->
        :ok

      :error ->
        put_state(macro_name, room_name, defaults)
    end
  end

  @doc "Get persistent state for a macro in a room."
  @spec get_state(String.t(), String.t()) :: {:ok, map()} | :error
  def get_state(macro_name, room_name) do
    case :ets.lookup(@table, {macro_name, room_name}) do
      [{_, state}] -> {:ok, state}
      [] -> load_from_disk(macro_name, room_name)
    end
  end

  @doc "Put persistent state for a macro in a room. Writes to ETS and disk."
  @spec put_state(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def put_state(macro_name, room_name, state) when is_map(state) do
    GenServer.call(__MODULE__, {:put_state, macro_name, room_name, state})
  end

  # --- Public API: Session state ---

  @doc "Get session state for a room (seen-sets, discovered macros, versions)."
  @spec get_session(String.t()) :: Cranium.Macro.Trigger.session_state()
  def get_session(room_name) do
    case :ets.lookup(@session_table, room_name) do
      [{_, session}] -> session
      [] -> %{}
    end
  end

  @doc "Update session state for a room."
  @spec put_session(String.t(), Cranium.Macro.Trigger.session_state()) :: :ok
  def put_session(room_name, session) when is_map(session) do
    :ets.insert(@session_table, {room_name, session})
    :ok
  end

  @doc "Clear session state for a room."
  @spec clear_session(String.t()) :: :ok
  def clear_session(room_name) do
    :ets.delete(@session_table, room_name)
    :ok
  end

  @doc "Clear persistent state for a macro in a room (ETS + disk)."
  @spec clear_state(String.t(), String.t()) :: :ok
  def clear_state(macro_name, room_name) do
    :ets.delete(@table, {macro_name, room_name})

    case state_file_path(macro_name, room_name) do
      nil -> :ok
      path -> File.rm(path)
    end

    :ok
  end

  # --- GenServer ---

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    :ets.new(@session_table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:put_state, macro_name, room_name, state}, _from, s) do
    :ets.insert(@table, {{macro_name, room_name}, state})

    case write_to_disk(macro_name, room_name, state) do
      :ok -> {:reply, :ok, s}
      {:error, _} = err -> {:reply, err, s}
    end
  end

  # --- Disk I/O ---

  defp load_from_disk(macro_name, room_name) do
    path = state_file_path(macro_name, room_name)

    if path && File.exists?(path) do
      with {:ok, content} <- File.read(path),
           {:ok, state} <- Jason.decode(content) do
        :ets.insert(@table, {{macro_name, room_name}, state})
        {:ok, state}
      else
        {:error, reason} ->
          Logger.warning("Macro.State: failed to read #{path}: #{inspect(reason)}")
          :error
      end
    else
      :error
    end
  end

  defp write_to_disk(macro_name, room_name, state) do
    case state_file_path(macro_name, room_name) do
      nil ->
        # No state path configured — ETS only
        :ok

      path ->
        dir = Path.dirname(path)
        File.mkdir_p!(dir)

        # Atomic write: tmp file + rename
        tmp_path = "#{path}.tmp.#{System.unique_integer([:positive])}"

        with {:ok, json} <- Jason.encode(state, pretty: true),
             :ok <- File.write(tmp_path, json),
             :ok <- File.rename(tmp_path, path) do
          :ok
        else
          {:error, reason} ->
            # Clean up tmp file on failure
            File.rm(tmp_path)
            Logger.warning("Macro.State: failed to write #{path}: #{inspect(reason)}")
            {:error, reason}
        end
    end
  end

  defp state_file_path(macro_name, room_name) do
    case state_path() do
      nil -> nil
      base -> Path.join([base, sanitize(room_name), "#{sanitize(macro_name)}.json"])
    end
  end

  defp sanitize(name) do
    name
    |> String.replace(~r/[^a-zA-Z0-9_-]/, "_")
    |> String.trim_leading(".")
  end

  defp state_path do
    case Application.get_env(:cranium, :paths) do
      paths when is_list(paths) -> Keyword.get(paths, :macros_state)
      _ -> nil
    end
  end
end
