defmodule Cranium.Plugin.Server do
  @moduledoc """
  GenServer wrapper for plugin modules.

  Handles OTP boilerplate so plugins only implement callbacks. Provides
  crash isolation — if a hook callback raises, the server logs a warning
  and returns `:skip` for that invocation rather than crashing the process.

  ## Startup

  `start_link/1` calls `module.init(session_metadata)`. If init returns
  `:ignore`, no process is started (standard OTP).

  ## Hook dispatch

  `call_hook/3` invokes a hook callback synchronously with a 5-second timeout.
  On timeout or crash, returns `{:error, reason}` — the caller (TurnAssembler)
  treats this as `:skip`.
  """

  use GenServer
  require Logger

  @hook_timeout 5_000

  @type start_opts :: [
          module: module(),
          session_metadata: Cranium.Plugin.session_metadata(),
          name: GenServer.name()
        ]

  @spec start_link(start_opts()) :: GenServer.on_start()
  def start_link(opts) do
    module = Keyword.fetch!(opts, :module)
    metadata = Keyword.fetch!(opts, :session_metadata)
    name = Keyword.get(opts, :name)

    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, {module, metadata}, gen_opts)
  end

  @doc """
  Invoke a hook on a running plugin server.

  Returns `{:ok, result}` on success, `{:error, reason}` on failure.
  The caller should treat errors as `:skip`.
  """
  @spec call_hook(pid(), :before_context_build, Cranium.Plugin.turn_context()) ::
          {:ok, :skip | [Cranium.Plugin.injection()]} | {:error, term()}
  def call_hook(pid, hook, context) do
    GenServer.call(pid, {:hook, hook, context}, @hook_timeout)
  catch
    :exit, reason ->
      Logger.warning("Plugin.Server: hook #{hook} failed", reason: inspect(reason))
      {:error, reason}
  end

  @doc "Return the module and subscribed hooks for a running plugin server."
  @spec info(pid()) :: {:ok, %{module: module(), hooks: [Cranium.Plugin.hook()]}} | {:error, term()}
  def info(pid) do
    GenServer.call(pid, :info)
  catch
    :exit, reason -> {:error, reason}
  end

  # --- GenServer callbacks ---

  @impl true
  def init({module, metadata}) do
    case module.init(metadata) do
      {:ok, hooks, state} ->
        Logger.info("Plugin.Server: #{inspect(module)} started",
          hooks: inspect(hooks),
          conversation_id: metadata.conversation_id
        )

        {:ok, %{module: module, hooks: hooks, state: state}}

      :ignore ->
        :ignore
    end
  end

  @impl true
  def handle_call({:hook, hook, turn_context}, _from, data) do
    if hook in data.hooks do
      case safe_callback(data.module, hook, [turn_context, data.state]) do
        {:ok, result, new_state} ->
          {:reply, {:ok, result}, %{data | state: new_state}}

        {:error, reason} ->
          {:reply, {:error, reason}, data}
      end
    else
      {:reply, {:ok, :skip}, data}
    end
  end

  @impl true
  def handle_call(:info, _from, data) do
    {:reply, {:ok, %{module: data.module, hooks: data.hooks}}, data}
  end

  defp safe_callback(module, callback, args) do
    case apply(module, callback, args) do
      {:ok, result, new_state} -> {:ok, result, new_state}
      other -> {:error, {:unexpected_return, other}}
    end
  rescue
    e ->
      Logger.warning("Plugin.Server: #{inspect(module)}.#{callback} raised",
        error: Exception.message(e)
      )

      {:error, {:raised, e}}
  end
end
