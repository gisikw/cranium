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

  @marker_tools ~w(show show_code play_audio)

  @type route_result ::
          {:marker, atom(), map()}
          | {:execute, module(), map()}
          | {:muse, String.t(), map()}
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
        {:marker, String.to_existing_atom(name), input}

      Cranium.Muse.handles?(name) ->
        {:muse, name, input}

      true ->
        find_handler(name, input)
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
  def tool_definitions do
    marker_defs =
      Enum.map(@marker_tools, fn name ->
        %{
          name: name,
          description: "Display marker: #{name}",
          input_schema: %{type: "object", properties: %{}}
        }
      end)

    clear_def = %{
      name: "clear_context",
      description: """
      Clear the current context and start a fresh epoch. Use this when context is getting full
      or when you want to reset the conversation state. A handoff document will be generated
      to preserve important context for the next epoch.

      If you provide a continuation, that instruction will be executed automatically after
      the handoff completes — use this when you want to continue working after clearing
      (e.g., "implement the plan we discussed").
      """,
      input_schema: %{
        type: "object",
        properties: %{
          continuation: %{
            type: "string",
            description: "Optional instruction to execute after context is cleared and handoff completes"
          }
        }
      }
    }

    registered_defs =
      Application.get_env(:cranium, :tools, [])
      |> Enum.map(fn {_name, module} -> module.schema() end)

    muse_defs = Cranium.Muse.tool_definitions()

    [clear_def | marker_defs] ++ muse_defs ++ registered_defs
  end

  defp find_handler(name, input) do
    case Application.get_env(:cranium, :tools, []) |> List.keyfind(name, 0) do
      {_, module} -> {:execute, module, input}
      nil -> {:unknown, name}
    end
  end
end
