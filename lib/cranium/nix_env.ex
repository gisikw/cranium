defmodule Cranium.NixEnv do
  @moduledoc """
  Caches nix devShell environments for project directories.

  When a working directory contains a `flake.nix`, resolves the devShell's
  PATH via `nix print-dev-env` and caches it. On subsequent calls, checks
  `flake.nix` mtime — if unchanged, returns the cached PATH instantly. If
  modified (e.g. the agent updated the flake mid-session), re-evaluates.

  Returns a list of `{charlist, charlist}` tuples suitable for merging into
  `Port.open/2`'s `:env` option.
  """

  use GenServer
  require Logger

  @table __MODULE__

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Get the devShell env overrides for a working directory.

  Returns a list of `{key, value}` charlists for Port `:env`, or `[]` if
  the directory has no flake.nix.
  """
  @spec env_for(String.t() | nil) :: [{charlist(), charlist()}]
  def env_for(nil), do: []

  def env_for(working_dir) do
    flake_path = Path.join(working_dir, "flake.nix")

    case File.stat(flake_path) do
      {:ok, %{mtime: mtime}} ->
        case :ets.lookup(@table, working_dir) do
          [{^working_dir, cached_mtime, env}] when cached_mtime == mtime ->
            env

          _ ->
            # Run resolution in the GenServer so System.cmd's port EXIT
            # signals don't pollute the caller's mailbox (which may trap exits).
            GenServer.call(__MODULE__, {:resolve, working_dir, flake_path, mtime}, 30_000)
        end

      {:error, _} ->
        []
    end
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:resolve, working_dir, flake_path, mtime}, _from, state) do
    # Double-check cache inside the serialized call to avoid duplicate work
    result =
      case :ets.lookup(@table, working_dir) do
        [{^working_dir, cached_mtime, env}] when cached_mtime == mtime ->
          env

        _ ->
          resolve_and_cache(working_dir, flake_path, mtime)
      end

    {:reply, result, state}
  end

  defp resolve_and_cache(working_dir, _flake_path, mtime) do
    Logger.info("Resolving nix devShell env", working_dir: working_dir)

    case resolve_nix_path(working_dir) do
      {:ok, nix_path} ->
        # Prepend nix PATH to the system PATH
        system_path = System.get_env("PATH") || ""
        merged_path = "#{nix_path}:#{system_path}"
        env = [{~c"PATH", String.to_charlist(merged_path)}]

        :ets.insert(@table, {working_dir, mtime, env})

        Logger.info("Nix devShell env cached",
          working_dir: working_dir,
          path_entries: length(String.split(nix_path, ":"))
        )

        env

      {:error, reason} ->
        Logger.warning("Failed to resolve nix devShell env: #{inspect(reason)} (#{working_dir})")

        # Negative cache — avoid re-running nix print-dev-env on every
        # message. Mtime check still applies: if the user fixes the flake,
        # the mtime changes and we retry.
        :ets.insert(@table, {working_dir, mtime, []})
        []
    end
  end

  defp resolve_nix_path(working_dir) do
    case System.cmd("nix", ["print-dev-env", working_dir],
           stderr_to_stdout: false,
           env: [{"NIX_CONFIG", "warn-dirty = false"}]
         ) do
      {output, 0} ->
        # Extract the PATH= line (first concrete assignment, single-quoted)
        case Regex.run(~r/^PATH='([^']+)'/m, output) do
          [_, path] -> {:ok, path}
          nil -> {:error, :no_path_found}
        end

      {_output, code} ->
        {:error, {:nix_exit, code}}
    end
  end
end
