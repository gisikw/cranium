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
