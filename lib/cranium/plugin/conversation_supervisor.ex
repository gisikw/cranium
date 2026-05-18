defmodule Cranium.Plugin.ConversationSupervisor do
  @moduledoc """
  Per-conversation DynamicSupervisor for plugin servers.

  Started as a child of `Cranium.Inference.Conversation`. On init, reads
  the profile's plugin declarations and starts a `Plugin.Server` for each.
  Plugins that return `:ignore` from init are silently skipped.

  Registered in ConversationRegistry as `{conversation_id, :plugins}`.
  """

  use DynamicSupervisor
  require Logger

  @registry Cranium.Inference.ConversationRegistry

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    conversation_id = Keyword.fetch!(opts, :conversation_id)
    DynamicSupervisor.start_link(__MODULE__, opts, name: via(conversation_id))
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Start plugins for a conversation from the profile's plugin declarations.

  Called by TurnAssembler on the first turn of an epoch, once the profile
  is resolved. Plugins that return `:ignore` are silently skipped.
  """
  @spec start_plugins(String.t(), Cranium.Plugin.session_metadata()) :: :ok
  def start_plugins(conversation_id, session_metadata) do
    plugins = session_metadata.profile.plugins || []

    case Registry.lookup(@registry, {conversation_id, :plugins}) do
      [{sup_pid, _}] ->
        # Idempotent — skip if plugins are already running
        if DynamicSupervisor.which_children(sup_pid) == [] do
          for %{module: module} = decl <- plugins do
            metadata = %{session_metadata | plugin_config: decl[:config]}

            child_spec = {
              Cranium.Plugin.Server,
              module: module, session_metadata: metadata
            }

            case DynamicSupervisor.start_child(sup_pid, child_spec) do
              {:ok, _pid} ->
                :ok

              :ignore ->
                Logger.debug("Plugin.ConversationSupervisor: #{inspect(module)} ignored session",
                  conversation_id: conversation_id
                )

              {:error, reason} ->
                Logger.warning(
                  "Plugin.ConversationSupervisor: failed to start #{inspect(module)}",
                  conversation_id: conversation_id,
                  reason: inspect(reason)
                )
            end
          end
        end

        :ok

      [] ->
        Logger.warning("Plugin.ConversationSupervisor: no supervisor for conversation",
          conversation_id: conversation_id
        )

        :ok
    end
  end

  @doc """
  Collect tool definitions from all active plugins for a conversation.

  Returns a list of `{tool_name, plugin_pid, tool_definition}` tuples.
  Used by ToolRouter to merge plugin tools with builtins and to route
  tool calls back to the owning plugin.
  """
  @spec plugin_tools(String.t()) :: [{String.t(), pid(), Cranium.Plugin.tool_definition()}]
  def plugin_tools(conversation_id) do
    case Registry.lookup(@registry, {conversation_id, :plugins}) do
      [{sup_pid, _}] ->
        children = DynamicSupervisor.which_children(sup_pid)

        Enum.flat_map(children, fn
          {_, pid, :worker, _} when is_pid(pid) ->
            case Cranium.Plugin.Server.tool_definitions(pid) do
              defs when is_list(defs) and defs != [] ->
                Enum.map(defs, fn def -> {def.name, pid, def} end)

              _ ->
                []
            end

          _ ->
            []
        end)

      [] ->
        []
    end
  end

  @doc """
  Dispatch a tool call to the plugin that owns it.

  Returns `{:ok, content}` or `{:error, reason}`.
  """
  @spec dispatch_tool_call(pid(), Cranium.Plugin.tool_call_context()) ::
          {:ok, String.t()} | {:error, term()}
  def dispatch_tool_call(plugin_pid, tool_call_context) do
    Cranium.Plugin.Server.call_tool(plugin_pid, tool_call_context)
  end

  @doc """
  Dispatch on_epoch_start to all subscribed plugins for a conversation.

  Called when a new epoch is created (including successor epochs after clear).
  Plugins use this to rehydrate persistent cross-epoch state.
  """
  @spec dispatch_epoch_start(String.t(), Cranium.Plugin.epoch_start_context()) :: :ok
  def dispatch_epoch_start(conversation_id, context) do
    case Registry.lookup(@registry, {conversation_id, :plugins}) do
      [{sup_pid, _}] ->
        children = DynamicSupervisor.which_children(sup_pid)

        for {_, pid, :worker, _} when is_pid(pid) <- children do
          Cranium.Plugin.Server.call_hook(pid, :on_epoch_start, context)
        end

        :ok

      [] ->
        :ok
    end
  end

  @doc """
  Dispatch after_resolve_profile to all subscribed plugins for a conversation.

  Composable: each plugin receives the output of the previous plugin in
  declaration order. If a plugin crashes or times out, the context reverts
  to the last successful output. Returns the final resolved profile context.
  """
  @spec dispatch_after_resolve_profile(String.t(), Cranium.Plugin.resolved_profile_context()) ::
          Cranium.Plugin.resolved_profile_context()
  def dispatch_after_resolve_profile(conversation_id, context) do
    case Registry.lookup(@registry, {conversation_id, :plugins}) do
      [{sup_pid, _}] ->
        children = DynamicSupervisor.which_children(sup_pid)

        Enum.reduce(children, context, fn
          {_, pid, :worker, _}, acc when is_pid(pid) ->
            case Cranium.Plugin.Server.call_hook(pid, :after_resolve_profile, acc) do
              {:ok, %{} = new_context} -> new_context
              {:ok, :skip} -> acc
              {:error, _} -> acc
            end

          _, acc ->
            acc
        end)

      [] ->
        context
    end
  end

  @doc """
  Dispatch a hook to all active plugins for a conversation.

  Returns a flat list of injections from all plugins that responded.
  Plugins that return `:skip`, crash, or time out are silently excluded.
  """
  @spec dispatch_hook(String.t(), :before_context_build, Cranium.Plugin.turn_context()) ::
          [Cranium.Plugin.injection()]
  def dispatch_hook(conversation_id, hook, context) do
    case Registry.lookup(@registry, {conversation_id, :plugins}) do
      [{sup_pid, _}] ->
        children = DynamicSupervisor.which_children(sup_pid)

        children
        |> Enum.flat_map(fn
          {_, pid, :worker, _} when is_pid(pid) ->
            case Cranium.Plugin.Server.call_hook(pid, hook, context) do
              {:ok, :skip} -> []
              {:ok, injections} when is_list(injections) -> injections
              {:error, _} -> []
            end

          _ ->
            []
        end)

      [] ->
        []
    end
  end

  @doc """
  Dispatch after_pass_complete to all subscribed plugins for a conversation.

  State-updating hook — each plugin can update its internal state based on
  the assistant's output (e.g., tracking mentions of glossary terms in
  responses). Returns :ok; plugin crashes and timeouts are swallowed.
  """
  @spec dispatch_after_pass_complete(String.t(), Cranium.Plugin.pass_complete_context()) :: :ok
  def dispatch_after_pass_complete(conversation_id, context) do
    case Registry.lookup(@registry, {conversation_id, :plugins}) do
      [{sup_pid, _}] ->
        children = DynamicSupervisor.which_children(sup_pid)

        for {_, pid, :worker, _} when is_pid(pid) <- children do
          Cranium.Plugin.Server.call_hook(pid, :after_pass_complete, context)
        end

        :ok

      [] ->
        :ok
    end
  end

  @doc """
  Dispatch on_epoch_end to all subscribed plugins for a conversation.

  Fire-and-forget — no injections returned. Each plugin receives the
  epoch end context (conversation_id, epoch_id, messages) and can
  perform side effects (e.g., updating glossary files). Crashes and
  timeouts are logged and swallowed.
  """
  @spec dispatch_epoch_end(String.t(), Cranium.Plugin.epoch_end_context()) :: :ok
  def dispatch_epoch_end(conversation_id, context) do
    case Registry.lookup(@registry, {conversation_id, :plugins}) do
      [{sup_pid, _}] ->
        children = DynamicSupervisor.which_children(sup_pid)

        for {_, pid, :worker, _} when is_pid(pid) <- children do
          Cranium.Plugin.Server.call_hook(pid, :on_epoch_end, context)
        end

        :ok

      [] ->
        :ok
    end
  end

  defp via(conversation_id) do
    {:via, Registry, {@registry, {conversation_id, :plugins}}}
  end
end
