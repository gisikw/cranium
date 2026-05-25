defmodule Cranium.Inference.Agent.ToolRouter do
  @moduledoc """
  Routes tool calls to the appropriate handler.

  Distinguishes between:
  - **Real tools** — executed via ToolExecutor, results returned to model
  - **Marker tools** — intercepted by MarkerEmitter, fake success returned
    to model, positional marker emitted to output stream

  ## Tool Registration

  Tools are registered as a list of `{name, type, handler}` tuples:
  - `{:real, module}` — real tool, dispatched to handler module
  - `{:marker, atom}` — SCTE marker, handled by MarkerEmitter

  ## Approval

  Real tools may require user approval before execution. The approval
  flow is managed by the Session/Transport — ToolRouter just flags
  whether approval is needed.
  """

  @marker_tools ~w(show show_code play_audio switch_room)

  @type route_result ::
          {:marker, atom(), map()}
          | {:execute, module(), map()}
          | {:muse, String.t(), map()}
          | {:plugin, pid(), map()}
          | {:macro, String.t(), map()}
          | {:clear, String.t() | nil}
          | {:unknown, String.t()}

  @doc """
  Route a tool call to its handler.
  """
  @spec route(map()) :: route_result()
  def route(%{name: name, input: input}) do
    cond do
      name == "clear_context" ->
        {:clear, Map.get(input, "continuation")}

      name in @marker_tools ->
        {:marker, String.to_atom(name), input}

      Cranium.Muse.handles?(name) ->
        {:muse, name, input}

      true ->
        find_handler(name, input)
    end
  end

  @doc """
  Route a tool call, checking plugin tools for a specific conversation.

  Plugin tools are checked after builtins (clear, marker, muse) but before
  falling through to registered tools and :unknown.
  """
  @spec route(map(), String.t()) :: route_result()
  def route(%{name: name, input: input}, conversation_id) do
    cond do
      name == "clear_context" ->
        {:clear, Map.get(input, "continuation")}

      name in @marker_tools ->
        {:marker, String.to_atom(name), input}

      Cranium.Muse.handles?(name) ->
        {:muse, name, input}

      true ->
        case find_plugin_handler(name, conversation_id) do
          {:plugin, pid} ->
            {:plugin, pid, input}

          nil ->
            cond do
              name == "search_macros" -> {:macro, "search_macros", input}
              Cranium.Macro.Engine.macro_tool?(name) -> {:macro, name, input}
              true -> find_handler(name, input)
            end
        end
    end
  end

  @doc """
  Check if a tool call requires user approval.
  """
  @spec requires_approval?(String.t()) :: boolean()
  def requires_approval?(_tool_name) do
    # TODO: Implement approval rules (auto-approve list, deny list)
    false
  end

  @doc "Register a tool handler at runtime."
  @spec register(String.t(), module()) :: :ok
  def register(name, module) do
    tools = Application.get_env(:cranium, :tools, [])
    Application.put_env(:cranium, :tools, [{name, module} | tools])
    :ok
  end

  @doc "Collect Anthropic tool definitions from all registered tools and marker tools."
  @spec tool_definitions() :: list(map())
  def tool_definitions, do: tool_definitions(nil)

  @doc """
  Collect tool definitions, including plugin tools for a conversation.

  When `conversation_id` is nil, returns only builtin tools.
  When provided, merges plugin-declared tools with builtins.
  """
  @spec tool_definitions(String.t() | nil) :: list(map())
  def tool_definitions(conversation_id) do
    clear_def = %{
      name: "clear_context",
      description: """
      Clear the current context and start a fresh epoch. Use when context is getting full or you want to reset conversation state. A handoff document will be generated to preserve important context. If you provide a continuation, that instruction executes automatically after handoff completes.
      """,
      input_schema: %{
        type: "object",
        properties: %{
          continuation: %{
            type: "string",
            description: "Optional instruction to execute after context is cleared and handoff completes. Keep this BRIEF (1-2 sentences) — a detailed handoff document from the outgoing session is automatically injected into the new session, so do NOT repeat conversation context here. Use this only to guide the resumption tone or next action (e.g., 'continue the conversation' or 'pick up where we left off on the work topic')."
          }
        }
      }
    }

    muse_defs = Cranium.Muse.tool_definitions()
    builtin_defs = [clear_def | muse_defs]

    plugin_defs =
      if conversation_id do
        conversation_id
        |> Cranium.Plugin.ConversationSupervisor.plugin_tools()
        |> Enum.map(fn {_name, _pid, def} -> def end)
      else
        []
      end

    # Macro tools: explicit-trigger macros with listed/discoverable advertising
    macro_defs =
      if conversation_id do
        Cranium.Macro.Engine.tool_definitions_for_room(conversation_id)
      else
        Cranium.Macro.Engine.tool_definitions()
      end

    # Search tool: available when any macro has searchable advertising
    search_defs =
      if Cranium.Macro.Registry.list_by_advertising(:searchable) != [] do
        [search_macros_tool_def()]
      else
        []
      end

    builtin_defs ++ plugin_defs ++ macro_defs ++ search_defs
  end

  defp find_handler(name, input) do
    case Application.get_env(:cranium, :tools, []) |> List.keyfind(name, 0) do
      {_, module} -> {:execute, module, input}
      nil -> {:unknown, name}
    end
  end

  defp search_macros_tool_def do
    %{
      name: "search_macros",
      description:
        "Search available macros by keyword. Returns matching macro names and descriptions. Use when you need a capability that isn't in your current tool list.",
      input_schema: %{
        type: "object",
        properties: %{
          query: %{
            type: "string",
            description: "Search query — matched against macro names, descriptions, and tags"
          }
        },
        required: ["query"]
      }
    }
  end

  defp find_plugin_handler(name, conversation_id) do
    conversation_id
    |> Cranium.Plugin.ConversationSupervisor.plugin_tools()
    |> Enum.find_value(fn
      {^name, pid, _def} -> {:plugin, pid}
      _ -> nil
    end)
  end
end
