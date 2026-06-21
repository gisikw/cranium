defmodule Cranium.Plugin do
  @moduledoc """
  Behaviour for cranium plugins.

  Plugins are session-scoped actors that subscribe to hook points in the
  conversation lifecycle. They observe turns, maintain their own state,
  and optionally inject content into the context pipeline.

  ## Implementing a plugin

      defmodule MyPlugin do
        @behaviour Cranium.Plugin

        @impl true
        def init(metadata) do
          {:ok, [:before_context_build], %{room: metadata.room_name}}
        end

        @impl true
        def before_context_build(turn_context, state) do
          injection = %{priority: 25, content: "<my-tag>hello</my-tag>"}
          {:ok, [injection], state}
        end
      end

  ## Lifecycle

  `init/1` is called when the conversation epoch starts (or on process restart).
  Return `{:ok, hooks, state}` to opt in, `{:ok, hooks, tool_defs, state}` to
  opt in with tool definitions, or `:ignore` to skip this session.

  `before_context_build/2` fires after history assembly, before the injection
  pipeline runs. Return `:skip` to contribute nothing, or a list of injections
  with priority and pre-tagged content.

  `on_epoch_start/2` fires when a new epoch is created (including successors
  after a clear). Receives `epoch_start_context` with predecessor info.
  Primary use case: rehydrating persistent cross-epoch state.

  `on_epoch_end/2` fires when the epoch is clearing, before handoff generation
  and plugin termination. Receives the full message history for the epoch.
  Return `:ok` — this is a side-effect-only hook (e.g., updating glossary
  entries based on conversation content).

  ## Tool declarations

  Plugins can declare tools by returning `{:ok, hooks, tool_defs, state}` from
  `init/1`. Tool definitions follow the Anthropic API format (name, description,
  input_schema). When declared, the ToolRouter merges plugin tools with builtins
  and routes invocations back to the plugin via `handle_tool_call/2`.

  ## Injection priorities (builtins for reference)

  - 10: time-gap / fresh-time
  - 20: landscape
  - 30: saturation
  - 40: interrupted-context
  """

  @type hook ::
          :after_resolve_profile
          | :before_context_build
          | :after_pass_complete
          | :on_epoch_start
          | :on_epoch_end

  @type session_metadata :: %{
          conversation_id: String.t(),
          epoch_id: String.t(),
          room_name: String.t(),
          profile: Cranium.Config.Profile.t(),
          plugin_config: map() | nil
        }

  @type resolved_profile_context :: %{
          conversation_id: String.t(),
          epoch_id: String.t(),
          turn_count: non_neg_integer(),
          profile_name: String.t(),
          backend: atom(),
          backend_module: module(),
          model: String.t() | nil,
          identity: String.t() | nil,
          thinking: boolean() | nil,
          router_profile: String.t() | nil,
          backend_config: map(),
          context_window: pos_integer() | nil,
          saturation_warn: number() | nil,
          saturation_critical: number() | nil
        }

  @type turn_context :: %{
          conversation_id: String.t(),
          epoch_id: String.t(),
          turn_count: non_neg_integer(),
          message_text: String.t()
        }

  @type pass_complete_context :: %{
          conversation_id: String.t(),
          epoch_id: String.t(),
          output: String.t(),
          turn_count: non_neg_integer()
        }

  @type epoch_end_context :: %{
          conversation_id: String.t(),
          epoch_id: String.t(),
          messages: [map()]
        }

  @type epoch_start_context :: %{
          conversation_id: String.t(),
          epoch_id: String.t(),
          predecessor_epoch_id: String.t() | nil,
          room_name: String.t()
        }

  @type tool_definition :: %{
          name: String.t(),
          description: String.t(),
          input_schema: map()
        }

  @type tool_call_context :: %{
          conversation_id: String.t(),
          epoch_id: String.t(),
          turn_count: non_neg_integer(),
          tool_call_id: String.t(),
          tool_name: String.t(),
          input: map()
        }

  @type injection :: %{priority: integer(), content: String.t()}

  @callback init(session_metadata()) ::
              {:ok, [hook()], state :: term()}
              | {:ok, [hook()], [tool_definition()], state :: term()}
              | :ignore

  @callback after_resolve_profile(resolved_profile_context(), state :: term()) ::
              {:ok, resolved_profile_context(), new_state :: term()}

  @callback before_context_build(turn_context(), state :: term()) ::
              {:ok, :skip | [injection()], new_state :: term()}

  @callback after_pass_complete(pass_complete_context(), state :: term()) ::
              {:ok, new_state :: term()}

  @callback on_epoch_start(epoch_start_context(), state :: term()) ::
              {:ok, new_state :: term()}

  @callback on_epoch_end(epoch_end_context(), state :: term()) :: :ok

  @callback handle_tool_call(tool_call_context(), state :: term()) ::
              {:ok, String.t(), new_state :: term()}
              | {:error, String.t(), new_state :: term()}

  @optional_callbacks [
    after_resolve_profile: 2,
    before_context_build: 2,
    after_pass_complete: 2,
    on_epoch_start: 2,
    on_epoch_end: 2,
    handle_tool_call: 2
  ]
end
