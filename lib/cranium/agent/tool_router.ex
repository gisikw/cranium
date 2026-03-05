defmodule Cranium.Agent.ToolRouter do
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
          | {:unknown, String.t()}

  @doc """
  Route a tool call to its handler.
  """
  @spec route(map()) :: route_result()
  def route(%{name: name, input: input}) do
    cond do
      name in @marker_tools ->
        {:marker, String.to_existing_atom(name), input}

      true ->
        # TODO: Look up registered tool handlers
        {:unknown, name}
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
end
